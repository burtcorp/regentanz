#!/usr/bin/env ruby

module Regentanz
  class TemplateCompiler
    ParseError = Class.new(Regentanz::Error)
    ValidationError = Class.new(Regentanz::Error)
    AmbiguityError = Class.new(Regentanz::Error)

    def initialize(options = {})
      @resource_compilers = {}
      @cf_client = options[:cloud_formation_client] || Aws::CloudFormation::Client.new(region: ENV.fetch('AWS_REGION', 'eu-west-1'))
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
      options = compiled.merge(options) { |_, v1, v2| v1.merge(v2) }
      if (parameters = options[:parameters]) && !parameters.empty?
        parameters, metadata = compile_parameters(parameters)
        template['Parameters'] = parameters
        template['Metadata'] = {'AWS::CloudFormation::Interface' => metadata}
      end
      template['Mappings'] = expand_refs(options[:mappings]) if options[:mappings]
      template['Conditions'] = expand_refs(options[:conditions]) if options[:conditions]
      template['Outputs'] = expand_refs(options[:outputs]) if options[:outputs]
      template
    end

    def validate_template(template)
      @cf_client.validate_template(template_body: template)
    rescue Aws::Errors::MissingCredentialsError => e
      raise ValidationError, 'Validation requires AWS credentials', e.backtrace
    rescue Aws::CloudFormation::Errors::ValidationError => e
      raise ValidationError, "Invalid template: #{e.message}", e.backtrace
    end

    private

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
          compiled.merge!(resource_compiler(type).compile(name, resource)) { |_, v1, v2| v1.merge(v2) }
        else
          compiled[:resources][name] = expand_refs(resource)
        end
      end
      compiled
    end

    def resource_compiler(type)
      @resource_compilers[type] ||= begin
        type = type.split('::').reduce(Object, &:const_get).new
      rescue NameError
        raise Regentanz::Error, "No resource compiler for #{type}"
      end
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

    def expand_refs(resource)
      case resource
      when Hash
        if (reference = resource.delete('ResolveRef'))
          resource.merge('Ref' => relative_path_to_name(reference))
        elsif (reference = resource.delete('ResolveName'))
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
