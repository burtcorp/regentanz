module Regentanz
  class TemplateCompiler
    ParseError = Class.new(Regentanz::Error)
    ValidationError = Class.new(Regentanz::Error)
    AmbiguityError = Class.new(Regentanz::Error)
    CredentialsError = Class.new(Regentanz::Error)
    TemplateError = Class.new(Regentanz::Error)

    def initialize(options = {})
      @resource_compilers = {}
      @region = ENV.fetch('AWS_REGION', 'eu-west-1')
      @cf_client = options[:cloud_formation_client] || Aws::CloudFormation::Client.new(region: @region)
      @s3_client = options[:s3_client] || Aws::S3::Resource.new(region: @region)
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
      end
      compile_template(resources, options)
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
        upload_template(stack_path, template) do |template_url|
          @cf_client.validate_template(template_url: template_url)
        end
      else
        @cf_client.validate_template(template_body: template)
      end
    rescue Aws::CloudFormation::Errors::ValidationError => e
      raise ValidationError, "Invalid template: #{e.message}", e.backtrace
    end

    TEMPLATE_VALIDATION_BUCKET = 'cf-templates-jn3m2hocei1o-%<region>s'
    TEMPLATE_VALIDATION_KEY = 'regentanz/%<stack>s-%<timestamp>s.json'
    def upload_template(stack_path, template)
      bucket = TEMPLATE_VALIDATION_BUCKET % {region: @region}
      key = TEMPLATE_VALIDATION_KEY % {stack: stack_path.gsub('/', '_'), timestamp: Time.now.to_i}
      obj = @s3_client.bucket(bucket).object(key)
      obj.put(body: template)
      yield obj.public_url
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

    YAML.add_domain_type('regentanz', 'GetAtt') do |_, value|
      {'Fn::GetAtt' => value.to_s.split('.')}
    end
    %w[Ref ResolveRef].each do |name|
      YAML.add_domain_type('regentanz', name) do |tag, value|
        {name => value}
      end
    end
    %w[FindInMap GetAZs ImportValue Join Select Split Sub].each do |name|
      YAML.add_domain_type('regentanz', name) do |tag, value|
        {['Fn', name].join('::') => value}
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
  end
end
