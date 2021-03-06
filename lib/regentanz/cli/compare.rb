require 'regentanz'
require 'regentanz/cli/common'

module Regentanz
  module Cli
    class Diff
      def initialize(new_object, old_object)
        @new_object = new_object
        @old_object = old_object
      end

      def to_json(*args)
        %(\e[31m#{@old_object.to_json(*args)}\e[m\e[32m#{@new_object.to_json(*args)}\e[m)
      end
    end

    class Compare
      include Common

      def run(args)
        config = load_config
        stack_name, stack_path, _ = *args
        compiler = TemplateCompiler.new(config)
        new_template = compiler.compile_from_path(stack_path)
        compiler.validate_template(stack_path, new_template.to_json)
        old_template = get_template(config, stack_name)
        diff = compare(new_template, old_template)
        if diff.to_json != new_template.to_json
          output = JSON.pretty_generate(diff)
          puts(output)
          1
        else
          0
        end
      rescue Regentanz::Error => e
        $stderr.puts(e.message)
        2
      end

      private

      def get_template(config, stack_name)
        cf_client = Aws::CloudFormation::Client.new(region: config['default_region'])
        YAML.load(cf_client.get_template(stack_name: stack_name)[:template_body])
      rescue Aws::Errors::MissingCredentialsError => e
        raise Regentanz::Error, 'Retrieving template requires AWS credentials', e.backtrace
      end

      def compare(new_template, old_template)
        if new_template.is_a?(Date) && old_template.is_a?(String)
          new_template = new_template.to_s
        end
        if new_template.class != old_template.class
          Diff.new(new_template, old_template)
        else
          case new_template
          when Hash
            result = {}
            new_template.each do |(key, value)|
              result[key] = compare(value, old_template[key])
            end
            old_template.each do |(key, value)|
              result[key] = compare(nil, value) unless new_template.key?(key)
            end
            result
          when Array
            if new_template.size != old_template.size
              Diff.new(new_template, old_template)
            else
              new_template.zip(old_template).map do |(left, right)|
                compare(left, right)
              end
            end
          else
            if new_template == old_template
              new_template
            else
              Diff.new(new_template, old_template)
            end
          end
        end
      end
    end
  end
end
