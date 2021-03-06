module Regentanz
  class TemplateCompiler
    ParseError = Class.new(Regentanz::Error)
    ValidationError = Class.new(Regentanz::Error)
    AmbiguityError = Class.new(Regentanz::Error)
    CredentialsError = Class.new(Regentanz::Error)
    TemplateError = Class.new(Regentanz::Error)

    def initialize(config, cloud_formation_client: nil, s3_client: nil)
      @resource_compilers = {}
      @region = config['default_region']
      @template_url = config['template_url']
      @cf_client = cloud_formation_client || Aws::CloudFormation::Client.new(region: @region)
      @s3_client = s3_client || Aws::S3::Resource.new(region: @region)
    rescue Aws::Sigv4::Errors::MissingCredentialsError => e
      raise CredentialsError, 'Validation requires AWS credentials'
    end

    def compile_from_path(stack_path)
      resources = []
      options = {}
      Dir.chdir(stack_path) do
        options[:parameters] = load_top_level_file('parameters')
        options[:mappings] = load_top_level_file('mappings')
        options[:conditions] = load_top_level_file('conditions')
        options[:outputs] = load_top_level_file('outputs')
        resources = load_resources
        compile_template(resources, options)
      end
    end

    def compile_template(resources, options = {})
      template = {'AWSTemplateFormatVersion' => '2010-09-09'}
      compiled = compile_resources(resources)
      template['Resources'] = compiled.delete(:resources)
      options = compiled.merge(options) { |_, v1, v2| v1.merge(v2 || {}) }
      if (parameters = options[:parameters]) && !parameters.empty?
        parameters, metadata = compile_parameters(parameters)
        template['Parameters'] = parameters
        template['Metadata'] = {'AWS::CloudFormation::Interface' => metadata}
      end
      template['Mappings'] = expand_refs(options[:mappings]) if options[:mappings]
      template['Conditions'] = expand_refs(options[:conditions]) if options[:conditions]
      template['Outputs'] = expand_refs(options[:outputs]) if options[:outputs]
      validate_parameter_use(template)
      template
    end

    def validate_template(stack_path, template)
      if template.bytesize > 460800
        raise TemplateError, "Compiled template is too large: #{template.bytesize} bytes > 460800"
      elsif template.bytesize >= 51200
        template_url = upload_template(stack_path, template)
        @cf_client.validate_template(template_url: template_url)
      else
        @cf_client.validate_template(template_body: template)
      end
    rescue Aws::CloudFormation::Errors::ValidationError => e
      raise ValidationError, "Invalid template: #{e.message}", e.backtrace
    end

    private

    PSEUDO_PARAMETERS = [
      'AWS::AccountId',
      'AWS::NotificationARNs',
      'AWS::NoValue',
      'AWS::Region',
      'AWS::StackId',
      'AWS::StackName',
    ].map!(&:freeze).freeze

    def upload_template(stack_path, template)
      if @template_url
        if (captures = @template_url.match(%r{\As3://(?<bucket>[^/]+)/(?<key>.+)\z}))
          bucket = captures[:bucket]
          bucket = bucket.gsub('${AWS_REGION}', @region)
          key = captures[:key]
          key = key.gsub('${TEMPLATE_NAME}', File.basename(stack_path))
          key = key.gsub('${TIMESTAMP}', Time.now.to_i.to_s)
          obj = @s3_client.bucket(bucket).object(key)
          obj.put(body: template)
          obj.public_url
        else
          raise ValidationError, format('Malformed template URL: %p', @template_url)
        end
      else
        raise ValidationError, 'Unable to validate template: it is larger than 51200 bytes and no template URL has been configured'
      end
    end

    def validate_parameter_use(template)
      available = {}
      template.fetch('Parameters', {}).each_key { |key| available[key] = true }
      unused = available.dup
      PSEUDO_PARAMETERS.each { |key| available[key] = true }
      template.fetch('Resources', {}).each_key { |key| available[key] = true }
      undefined = {}
      each_ref(template) do |key|
        unused.delete(key)
        undefined[key] = true unless available[key]
      end
      unless unused.empty?
        raise ValidationError, "Unused parameters: #{unused.keys.join(', ')}"
      end
      unless undefined.empty?
        raise ValidationError, "Undefined parameters: #{undefined.keys.join(', ')}"
      end
    end

    def load_top_level_file(name)
      matches = Dir["#{name}.{json,yml,yaml}"]
      case matches.size
      when 1
        load(matches.first)
      when 0
        nil
      else
        sprintf('Found multiple files when looking for %s: %s', name, matches.join(', '))
        raise AmbiguityError, message
      end
    end

    def load_resources
      Dir['resources/**/*.{json,yml,yaml}'].sort.each_with_object({}) do |path, acc|
        relative_path = path.sub(/^resources\//, '')
        acc[relative_path] = load(path)
      end
    end

    def load(path)
      YAML.load_file(path)
    rescue Psych::SyntaxError => e
      raise ParseError, sprintf('Invalid template fragment: %s', e.message), e.backtrace
    end

    def compile_resources(resources)
      compiled = {resources: {}}
      resources.map do |relative_path, resource|
        name = relative_path_to_name(relative_path)
        if (type = resource['Type']).start_with?('Regentanz::Resources::')
          expanded_template = resource_compiler(type).compile(name, resource)
          expanded_template[:resources] = expand_refs(expanded_template[:resources])
          compiled.merge!(expanded_template) { |_, v1, v2| v1.merge(v2) }
        else
          compiled[:resources][name] = expand_refs(resource)
        end
      end
      compiled
    end

    def resource_compiler(type)
      @resource_compilers[type] ||= begin
        begin
          create_instance(type)
        rescue NameError
          begin
            load_resource_compiler(type)
            create_instance(type)
          rescue LoadError, NameError
            raise Regentanz::Error, "No resource compiler for #{type}"
          end
        end
      end
    end

    def create_instance(type)
      type.split('::').reduce(Object, &:const_get).new
    end

    def load_resource_compiler(type)
      require(type.gsub('::', '/').gsub(/\B[A-Z]/, '_\&').downcase)
    end

    def compile_parameters(specifications)
      groups = []
      parameters = {}
      specifications.each do |name, options|
        if options['Type'] == 'Regentanz::ParameterGroup'
          group_parameters = options['Parameters']
          parameters.merge!(group_parameters)
          groups << {
            'Label' => {'default' => name},
            'Parameters' => group_parameters.keys
          }
        else
          parameters[name] = options
        end
      end
      labels = parameters.each_with_object({}) do |(name, options), labels|
        if (label = options.delete('Label'))
          labels[name] = {'default' => label}
        end
      end
      metadata = {'ParameterGroups' => groups, 'ParameterLabels' => labels}
      return parameters, metadata
    end

    def relative_path_to_name(relative_path)
      name = relative_path.dup
      name.sub!(/\.([^.]+)$/, '')
      name.gsub!('/', '_')
      name.gsub!(/_.|^./) { |str| str[-1].upcase }
      name
    end

    def each_ref(resource, &block)
      case resource
      when Hash
        if (ref = resource['Ref'])
          yield ref
        elsif (substitution = resource['Fn::Sub'])
          case substitution
          when Array
            each_ref(substitution, &block)
          else
            substitution.scan(/\$\{([^}]+)\}/) do |matches|
              block.call(matches[0])
            end
          end
        else
          resource.each_value { |v| each_ref(v, &block) }
        end
      when Array
        resource.each { |v| each_ref(v, &block) }
      end
    end

    def expand_refs(resource)
      case resource
      when Hash
        if (reference = resource['ResolveRef'])
          expanded_name = relative_path_to_name(reference)
          expanded_resource = resource.merge('Ref' => expanded_name)
          expanded_resource.delete('ResolveRef')
          expanded_resource
        elsif (reference = resource['ResolveName'])
          relative_path_to_name(reference)
        elsif (reference = resource['Regentanz::ReadFile'])
          read_file(reference)
        else
          resource.merge(resource) do |_, v, _|
            expand_refs(v)
          end
        end
      when Array
        resource.map do |v|
          expand_refs(v)
        end
      else
        resource
      end
    end

    def read_file(filename)
      if File.exists?(filename)
        File.read(filename)
      else
        raise ParseError, "File #{filename} does not exist"
      end
    end
  end
end
