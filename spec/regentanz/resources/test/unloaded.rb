module Regentanz
  module Resources
    module Test
      class Unloaded
        def compile(name, resource)
          {:resources => {name => {'Type' => 'AWS::S3::Bucket'}}}
        end
      end
    end
  end
end
