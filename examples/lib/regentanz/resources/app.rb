module Regentanz
  module Resources
    class App
      def compile(name, template)
        {
          :parameters => compile_parameters(name),
          :resources => {
            "#{name}Asg" => compile_asg(name, template['Properties']),
            "#{name}Lc" => compile_lc(name, template['Properties']),
            "#{name}Sg" => compile_sg(name, template['Properties']),
          }
        }
      end

      private

      def compile_parameters(name)
        {
          "#{name} parameters" => {
            'Type' => 'Regentanz::ParameterGroup',
            'Parameters' => {
              "#{name}Count" => {
                'Label' => 'Instance count',
                'Type' => 'Number',
                'Default' => 3,
                'MinValue' => 1,
              },
              "#{name}InstanceType" => {
                'Label' => 'Instance type',
                'Type' => 'String',
                'Default' => 'm5.large',
              },
              "#{name}Ami" => {
                'Label' => 'Instance type',
                'Type' => 'String',
              },
            }
          }
        }
      end

      def compile_asg(name, properties)
        {
          'Type' => 'AWS::AutoScaling::AutoScalingGroup',
          'Properties' => {
            'AvailabilityZones' => {'Fn::GetAZs' => ''},
            'MinSize' => 0,
            'DesiredCapacity' => {'Ref' => "#{name}Count"},
            'MaxSize' => {'Ref' => "#{name}Count"},
            'LaunchConfigurationName' => {'Ref' => "#{name}Lc"},
            'Tags' => [
              {'Key' => 'Environment', 'Value' => {'Ref' => 'Environment'}, 'PropagateAtLaunch' => true},
              {'Key' => 'Name', 'Value' => {'Fn::Sub' => "${Environment}-#{properties['Name']}-asg"}},
            ],
          }
        }
      end

      def compile_lc(name, properties)
        {
          'Type' => 'AWS::AutoScaling::LaunchConfiguration',
          'Properties' => {
            'ImageId' => {'Ref' => "#{name}Ami"},
            'InstanceType' => {'Ref' => "#{name}InstanceType"},
            'IamInstanceProfile' => properties['IamInstanceProfile'],
            'SecurityGroups' => [
              {'Ref' => "#{name}Sg"}
            ],
          }
        }
      end

      def compile_sg(name, properties)
        {
          'Type' => 'AWS::EC2::SecurityGroup',
          'Properties' => {
            'GroupName' => {'Fn::Sub' => "${Environment}-#{properties['Name']}-sg"},
            'VpcId' => properties['VpcId'],
            'Tags' => [
              {'Key' => 'Environment', 'Value' => {'Ref' => 'Environment'}},
              {'Key' => 'Name', 'Value' => {'Fn::Sub' => "${Environment}-#{properties['Name']}-sg"}},
            ],
          }
        }
      end
    end
  end
end
