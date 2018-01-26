require 'yaml'

module Regentanz
  module Cli
    module Common
      private def load_config
        if (path = find_config('.'))
          config = YAML.load_file(path)
          Array(config['load_path']).each do |extra_load_path|
            if extra_load_path.start_with?('/')
              $LOAD_PATH << extra_load_path
            else
              $LOAD_PATH << File.absolute_path(extra_load_path, File.dirname(path))
            end
          end
        end
      end

      private def find_config(path)
        candidates = Dir[File.join(path, '.regentanz.{yaml,yml,json}')]
        if candidates.first
          candidates.first
        elsif path != '/'
          find_config(File.expand_path(File.join(path, '..')))
        else
          nil
        end
      end
    end
  end
end