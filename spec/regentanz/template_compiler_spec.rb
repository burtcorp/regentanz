require 'tmpdir'

module Regentanz
  module Resources
    module Test
      class SecurityGroupPair
        def compile(name, resource)
          {
            :resources => {
              "#{name}1" => resource.merge('Type' => 'AWS::EC2::SecurityGroup'),
              "#{name}2" => resource.merge('Type' => 'AWS::EC2::SecurityGroup'),
            }
          }
        end
      end

      class BucketAndPolicy
        def compile(name, resource)
          result = {:parameters => {}, :resources => {}, :mappings => {}, :conditions => {}}
          result[:parameters]['BucketName'] = {'Type' => 'String'}
          result[:resources][name + 'Bucket'] = {'Type' => 'AWS::S3::Bucket', 'Properties' => {'BucketName' => {'Ref' => 'BucketName'}}}
          result[:resources][name + 'Policy'] = {'Type' => 'AWS::IAM::Policy', 'Properties' => {'PolicyName' => 'SomePolicy'}}
          result[:mappings]['Prefix'] = {'production' => 'prod-', 'test' => 'test-'}
          result[:conditions]['IsEu'] = {'Fn::Equals' => [{'Ref' => 'AWS::Region'}, 'eu-west-1']}
          result
        end
      end
    end
  end

  describe TemplateCompiler do
    let :compiler do
      described_class.new(config, cloud_formation_client: cf_client, s3_client: s3_client)
    end

    let :config do
      {
        'default_region' => 'ap-southeast-1',
      }
    end

    let :cf_client do
      double(:cf_client)
    end

    let :s3_client do
      double(:s3)
    end

    before do
      allow(cf_client).to receive(:validate_template)
    end

    describe '#compile_template' do
      let :resources do
        {
          'core/ec2_instance.json' => {
            'Type' => 'AWS::EC2::Instance',
            'Properties' => {
              'ImageId' => {'Fn::FindInMap' => ['Ami', 'amzn-ami-2016.03.1', 'hvm']},
            }
          },
          'core/asg.json' => {
            'Type' => 'AWS::AutoScaling::AutoScalingGroup',
            'Properties' => {
              'MinSize' => {'Ref' => 'MinInstances'},
              'MaxSize' => {'Ref' => 'MaxInstances'},
            }
          }
        }
      end

      let :parameters do
        {
          'MinInstances' => {
            'Type' => 'Number',
            'Default' => 1,
          },
          'MaxInstances' => {
            'Type' => 'Number',
            'Default' => 1,
          },
          'Environment' => {
            'Type' => 'String',
          },
          'Volume' => {
            'Type' => 'AWS::EC2::Volume',
          },
        }
      end

      let :mappings do
        {
          'Version' => {
            'Mongo' => {
              'production' => '2.6.0',
              'staging' => '3.4.0',
            },
          },
        }
      end

      let :conditions do
        {
          "Staging" => {"Fn::Equals" => [{"Ref" => "Environment"}, "staging"]},
        }
      end

      let :outputs do
        {
          "VolumeId" => {"Value" => { "Ref" => "Volume" }},
        }
      end

      let :template do
        compiler.compile_template(resources, parameters: parameters, mappings: mappings, conditions: conditions, outputs: outputs)
      end

      it 'generates an CloudFormation compatible template', aggregate_failures: true do
        expect(template['AWSTemplateFormatVersion']).to eq('2010-09-09')
        expect(template['Mappings']).to eq(mappings)
        expect(template['Conditions']).to eq(conditions)
        expect(template['Outputs']).to eq(outputs)
        expect(template['Resources']).to be_a(Hash)
        expect(template['Resources'].values).to eq(resources.values)
      end

      it 'names resources from their relative paths' do
        expect(template['Resources'].keys).to eq(%w[CoreEc2Instance CoreAsg])
      end

      it 'resolves references in resource definitions' do
        resources['extra'] = {
          'Type' => 'AWS::EC2::VolumeAttachment',
          'Properties' => {
            'InstanceId' => { 'ResolveRef' => 'core/ec2_instance' },
            'VolumeId' => { 'Ref' => 'Volume' },
            'Device' => '/dev/sdh',
          }
        }
        expect(template['Resources']['Extra']).to eq(
          'Type' => 'AWS::EC2::VolumeAttachment',
          'Properties' => {
            'InstanceId' => { 'Ref' => 'CoreEc2Instance' },
            'VolumeId' => { 'Ref' => 'Volume' },
            'Device' => '/dev/sdh',
          }
        )
      end

      it 'resolves reference names in resource definitions' do
        resources['extra'] = {
          'Type' => 'AWS::EC2::Instance',
          'Properties' => {
            'AvailabilityZone' => {'Fn::GetAtt' => [{'ResolveName' => 'core/ec2_instance'}]},
          }
        }
        expect(template['Resources']['Extra']).to eq(
          'Type' => 'AWS::EC2::Instance',
          'Properties' => {
            'AvailabilityZone' => {'Fn::GetAtt' => ['CoreEc2Instance']},
          }
        )
      end

      it 'reads external files in resource definitions' do
        Dir.mktmpdir do |dir|
          Dir.chdir(dir) do
            File.open('code.py', 'w') do |file|
              file.puts 'Some code 1'
              file.puts 'Some code 2'
            end

            resources['extra'] = {
              'Type' => 'AWS::Lambda::Function',
              'Properties' => {
                'Code' => {
                  'ZipFile' => {'Regentanz::ReadFile' => 'code.py'}
                }
              }
            }

            template = compiler.compile_template(resources, parameters: parameters, mappings: mappings, conditions: conditions, outputs: outputs, stack_path: dir)

            expect(template['Resources']['Extra']).to eq(
              'Type' => 'AWS::Lambda::Function',
              'Properties' => {
                'Code' => {
                  'ZipFile' => "Some code 1\nSome code 2\n"
                }
              }
            )
          end
        end
      end

      context 'with parameter labels' do
        it 'removes the Label key from parameters' do
          parameters['MinInstances']['Label'] = 'The X'
          expect(template['Parameters']['MinInstances']).not_to include('Label')
        end

        it 'adds parameter labels to the interface metadata' do
          parameters['MinInstances']['Label'] = 'The minimum number of instances'
          expect(template['Metadata']['AWS::CloudFormation::Interface']['ParameterLabels']).to eq('MinInstances' => {'default' => 'The minimum number of instances'})
        end
      end

      context 'with Regentanz::ParameterGroup' do
        let :parameters do
          super().merge(
            'Group' => {
              'Type' => 'Regentanz::ParameterGroup',
              'Parameters' => {
                'Nested' => {
                  'Type' => 'AWS::EC2::Instance',
                  'Properties' => {
                    'AvailabilityZone' => {'Fn::GetAtt' => ['CoreEc2Instance']},
                  }
                },
              }
            }
          )
        end

        let :resources do
          r = super()
          r['core/asg.json']['Properties']['AvailabilityZones'] = {'Ref' => 'Nested'}
          r
        end

        it 'removes the group parameters from the output' do
          expect(template['Parameters']).not_to include('Group')
        end

        it 'lifts the grouped parameters to the top level' do
          expect(template['Parameters'].keys).to include('Nested')
        end

        it 'adds parameter groups to the interface metadata' do
          expect(template['Metadata']['AWS::CloudFormation::Interface']['ParameterGroups']).to eq([{'Label' => {'default' => 'Group'}, 'Parameters' => ['Nested']}])
        end
      end

      context 'with a custom resource type' do
        let :resources do
          super().merge(
            'core/test.json' => {
              'Type' => 'Regentanz::Resources::Test::BucketAndPolicy',
              'Properties' => {
                'Name' => {'Ref' => 'CoreTestBucketName'},
              }
            },
            'core/lc.json' => {
              'Type' => 'AWS::AutoScaling::LaunchConfiguration',
              'Properties' => {
                'SecurityGroups' => [{'Ref' => 'AWS::NoValue'}]
              }
            },
          )
        end

        it 'does not add the uncompiled resource' do
          expect(template['Resources']).not_to include('CoreTest')
        end

        it 'adds resources from the compiled resource' do
          expect(template['Resources']).to include('CoreTestBucket', 'CoreTestPolicy')
        end

        it 'keeps existing resources' do
          expect(template['Resources']).to include('CoreEc2Instance')
        end

        it 'adds parameters from the compiled resource' do
          expect(template['Parameters']).to include('BucketName')
        end

        it 'keeps parameters from outside the resource' do
          expect(template['Parameters']).to include('MinInstances')
        end

        it 'adds mappings from the compiled resource' do
          expect(template['Mappings']).to include('Prefix')
        end

        it 'keeps parameters from outside the resource' do
          expect(template['Mappings']).to include('Version')
        end

        it 'adds conditions from the compiled resource' do
          expect(template['Conditions']).to include('IsEu')
        end

        it 'keeps conditions from outside the resource' do
          expect(template['Conditions']).to include('Staging')
        end

        context 'that contains a reference to another resource' do
          let :resources do
            r = super().merge(
              'core/sg.json' => {
                'Type' => 'Regentanz::Resources::Test::SecurityGroupPair',
                'Properties' => {
                  'GroupDescription' => {'Fn::Join' => [' ', 'SG for ', {'ResolveName' => 'core/vpc'}]},
                  'VpcId' => {'ResolveRef' => 'core/vpc'},
                }
              },
              'core/vpc.json' => {
                'Type' => 'AWS::EC2::VPC',
                'Properties' => {
                  'CidrBlock' => '10.0.0.0/8',
                }
              },
              'core/lc.json' => {
                'Type' => 'AWS::AutoScaling::LaunchConfiguration',
                'Properties' => {
                  'SecurityGroups' => [{'Ref' => 'AWS::NoValue'}]
                }
              },
            )
          end

          it 'resolves references in the resources returned by the custom resource' do
            aggregate_failures do
              expect(template['Resources']['CoreSg1']['Properties']['VpcId']).to eq({'Ref' => 'CoreVpc'})
              expect(template['Resources']['CoreSg1']['Properties']['GroupDescription']).to eq({'Fn::Join' => [' ', 'SG for ', 'CoreVpc']})
            end
          end

          it 'does not mutate the input template' do
            aggregate_failures do
              expect(template['Resources']['CoreSg2']['Properties']['VpcId']).to eq({'Ref' => 'CoreVpc'})
              expect(template['Resources']['CoreSg2']['Properties']['GroupDescription']).to eq({'Fn::Join' => [' ', 'SG for ', 'CoreVpc']})
            end
          end
        end

        context 'with nil valued options' do
          let :parameters do
            nil
          end

          let :conditions do
            nil
          end

          let :mappings do
            nil
          end

          let :outputs do
            nil
          end

          before do
            resources.delete_if { |k,v| k != 'core/test.json' }
          end

          it 'includes the values from the compiled resource', aggregate_failures: true do
            expect(template['Resources']).to include('CoreTestBucket', 'CoreTestPolicy')
            expect(template['Parameters']).to include('BucketName')
            expect(template['Conditions']).to include('IsEu')
            expect(template['Mappings']).to include('Prefix')
            expect(template).not_to include('Outputs')
          end
        end

        context 'when the resource is not loaded' do
          let :resources do
            super().merge(
              'core/unloaded_resource.json' => {
                'Type' => 'Regentanz::Resources::Test::Unloaded',
              }
            )
          end

          it 'converts the resource type to a path and loads it' do
            expect(template['Resources']).to include('CoreUnloadedResource')
          end
        end
      end

      context 'with an non-existant resource type' do
        let :resources do
          super().merge(
            'core/test.json' => {
              'Type' => 'Regentanz::Resources::NonexistantResource',
              'Properties' => {
                'Role' => 'core-role',
              }
            }
          )
        end

        it 'raises an error' do
          expect { template }.to raise_error(Regentanz::Error, 'No resource compiler for Regentanz::Resources::NonexistantResource')
        end
      end

      context 'when validating that parameters are used' do
        let :parameters do
          super().merge(
            'Foo' => {'Type' => 'String'},
            'Bar' => {'Type' => 'String'},
            'Baz' => {'Type' => 'String'},
          )
        end

        context 'and there are unused parameters' do
          it 'raises ValidationError' do
            expect { template }.to raise_error(described_class::ValidationError, 'Unused parameters: Foo, Bar, Baz')
          end
        end

        context 'and parameters are used in Fn::Sub' do
          let :resources do
            super().merge(
              'core/test.json' => {
                'Type' => 'AWS::EC2::Instance',
                'Properties' => {
                  'SomeProp' => {'Fn::Sub' => 'xyz:${Foo}/bar/${Baz}'},
                  'SomeOtherProp' => {'Fn::Sub' => ['${barbar}!', {'barbar' => {'Ref' => 'Bar'}}]},
                }
              }
            )
          end

          it 'detects the usage' do
            expect { template }.to_not raise_error
          end
        end
      end

      context 'when validating that no undefined parameters are used' do
        context 'and parameters are used in Fn::Sub' do
          let :resources do
            super().merge(
              'core/test.json' => {
                'Type' => 'AWS::EC2::Instance',
                'Properties' => {
                  'SomeProp' => {'Fn::Sub' => 'xyz:${Foo}/bar/${Baz}'},
                  'SomeOtherProp' => {'Fn::Sub' => ['${barbar}!', {'barbar' => {'Ref' => 'Bar'}}]},
                }
              }
            )
          end

          it 'raises ValidationError' do
            expect { template }.to raise_error(described_class::ValidationError, 'Undefined parameters: Foo, Baz, Bar')
          end
        end

        context 'and referring to other resources' do
          let :resources do
            super().merge(
              'core/test.json' => {
                'Type' => 'AWS::EC2::Instance',
                'Properties' => {
                  'SomeProp' => {'ResolveRef' => 'core/test2'}
                }
              },
            )
          end

          it 'raises ValidationError' do
            expect { template }.to raise_error(described_class::ValidationError, 'Undefined parameters: CoreTest2')
          end

          context 'when resource exists' do
            let :resources do
              super().merge(
                'core/test2.json' => {
                  'Type' => 'AWS::EC2::Instance',
                  'Properties' => {
                  }
                },
              )
            end

            it 'accepts the parameter' do
              expect { template }.not_to raise_error
            end
          end
        end

        context 'and using built-in pseudo parameters' do
          let :resources do
            super().merge(
              'core/test.json' => {
                'Type' => 'AWS::EC2::Instance',
                'Properties' => {
                  'SomeProp' => {'Ref' => 'AWS::Region'}
                }
              }
            )
          end

          it 'accepts the parameter' do
            expect { template }.not_to raise_error
          end
        end
      end
    end

    describe '#compile_from_path' do
      around do |example|
        Dir.mktmpdir do |dir|
          Dir.chdir(dir) do
            Dir.mkdir('template')
            example.call
          end
        end
      end

      let :template do
        compiler.compile_from_path('template')
      end

      it 'loads parameters, mappings, conditions, outputs from JSON files', aggregate_failures: true do
        File.write('template/parameters.json', '{"Parameter":{"Type":"Number"}}')
        File.write('template/mappings.json', '{"Mapping":{"A":{"B":"C"}}}')
        File.write('template/conditions.json', '{"Staging":{"Fn:Equals":[{"Ref":"AWS::Region"},{"Ref":"Parameter"}]}}')
        File.write('template/outputs.json', '{"VolumeId":{"Value":{"Ref":"Parameter"}}}')
        expect(template['Parameters'].keys).to eq(%w[Parameter])
        expect(template['Mappings'].keys).to eq(%w[Mapping])
        expect(template['Conditions'].keys).to eq(%w[Staging])
        expect(template['Outputs'].keys).to eq(%w[VolumeId])
      end

      it 'loads parameters, mappings, conditions, outputs from YAML files', aggregate_failures: true do
        File.write('template/parameters.yaml', 'Parameter: {Type: Number}')
        File.write('template/mappings.yaml', 'Mapping: {A: {B: C}}')
        File.write('template/conditions.yml', 'Staging: {"Fn:Equals": [{Ref: "AWS::Region"}, {Ref: Parameter}]}')
        File.write('template/outputs.yml', 'VolumeId: {Value: {Ref: Parameter}}')
        expect(template['Parameters'].keys).to eq(%w[Parameter])
        expect(template['Mappings'].keys).to eq(%w[Mapping])
        expect(template['Conditions'].keys).to eq(%w[Staging])
        expect(template['Outputs'].keys).to eq(%w[VolumeId])
      end

      it 'loads resource from JSON files' do
        Dir.mkdir 'template/resources'
        Dir.mkdir 'template/resources/core'
        File.write('template/resources/core/instance.json', '{"Type":"AWS::EC2::Instance"}')
        File.write('template/resources/attachment.json', '{"Type":"AWS::EC2::VolumeAttachment"}')
        expect(template['Resources'].keys.sort).to eq(%w[Attachment CoreInstance])
      end

      it 'loads resource from YAML files' do
        Dir.mkdir 'template/resources'
        Dir.mkdir 'template/resources/core'
        File.write('template/resources/core/instance.yaml', 'Type: AWS::EC2::Instance')
        File.write('template/resources/attachment.yml', 'Type: AWS::EC2::VolumeAttachment')
        expect(template['Resources'].keys.sort).to eq(%w[Attachment CoreInstance])
      end

      it 'handles short-form intrinsic functions in YAML' do
        Dir.mkdir 'template/resources'
        Dir.mkdir 'template/resources/core'
        File.write('template/resources/core/instance.json', '{"Type":"AWS::EC2::Instance"}')
        File.write('template/resources/volume.yml', <<-'YAML')
        Type: AWS::EC2::Volume,
        Properties:
          Size: !ImportValue VolumeSize
          AvailabilityZone: !GetAtt Instance.AvailabilityZone
          Tags:
            - Key: MyTag
              Value: !Sub "${Volume}-${Volume}"
        YAML
        File.write('template/resources/attachment.yml', <<-'YAML')
        Type: AWS::EC2::VolumeAttachment
        Properties:
          InstanceId: !ResolveRef core/instance
          VolumeId: !Ref Volume
          Device: !Join [/, ['', dev, sdh]]
        YAML
        expect(template['Resources']['Volume']['Properties']).to eq(
          'Size' => {'Fn::ImportValue' => 'VolumeSize'},
          'AvailabilityZone' => {'Fn::GetAtt' => ['Instance', 'AvailabilityZone']},
          'Tags' => [{'Key' => 'MyTag', 'Value' => {'Fn::Sub' => '${Volume}-${Volume}'}}],
        )
        expect(template['Resources']['Attachment']['Properties']).to eq(
          'InstanceId' => {'Ref' => 'CoreInstance'},
          'VolumeId' => {'Ref' => 'Volume'},
          'Device' => {'Fn::Join' => ['/', ['', 'dev', 'sdh']]},
        )
      end
    end

    describe '#validate_template' do
      it 'uses the CloudFormation API to validate the template' do
        compiler.validate_template('stack', 'my-template')
        expect(cf_client).to have_received(:validate_template).with(template_body: 'my-template')
      end

      it 'produces a validation error when template is invalid' do
        allow(cf_client).to receive(:validate_template).and_raise(Aws::CloudFormation::Errors::ValidationError.new(nil, 'boork'))
        expect { compiler.validate_template('stack', 'my-template') }.to raise_error(described_class::ValidationError, 'Invalid template: boork')
      end

      context 'when the compiled template is larger than 51200 bytes' do
        let :config do
          super().merge('template_url' => 's3://templates/validate-me.json')
        end

        let :large_template do
          '0' * 51201
        end

        let :bucket do
          double(:bucket)
        end

        let :s3_obj do
          double(:s3_obj)
        end

        before do
          allow(s3_client).to receive(:bucket).with('templates').and_return(bucket)
          allow(bucket).to receive(:object).with('validate-me.json').and_return(s3_obj)
          allow(s3_obj).to receive(:put)
          allow(s3_obj).to receive(:public_url).and_return('https://s3.amazonaws.com/templates/validate-me.json')
        end

        it 'uploads the template to S3 before validating the template' do
          compiler.validate_template('stack', large_template)
          expect(s3_obj).to have_received(:put).with(body: large_template).ordered
          expect(cf_client).to have_received(:validate_template).with(template_url: 'https://s3.amazonaws.com/templates/validate-me.json').ordered
        end

        context 'and the template URL contains variables' do
          let :config do
            super().merge('template_url' => 's3://templates-${AWS_REGION}/some/prefix/${TEMPLATE_NAME}/${TEMPLATE_NAME}-${TIMESTAMP}.json')
          end

          before do
            allow(s3_client).to receive(:bucket).and_return(bucket)
            allow(bucket).to receive(:object).and_return(s3_obj)
          end

          it 'replaces ${AWS_REGION} in the bucket name with the configured AWS region' do
            compiler.validate_template('stack', large_template)
            expect(s3_client).to have_received(:bucket).with('templates-ap-southeast-1')
          end

          it 'replaces ${TEMPLATE_NAME} in the key with the directory name of the template' do
            compiler.validate_template('some/path/to/a/template/called/foobar', large_template)
            expect(bucket).to have_received(:object).with(start_with('some/prefix/foobar/foobar-'))
          end

          it 'replaces ${TIMESTAMP} in the key with current time as a UNIX timestamp' do
            compiler.validate_template('some/path/to/a/template/called/foobar', large_template)
            expect(bucket).to have_received(:object).with(/-\d+\.json$/)
          end
        end

        context 'and the template URL is malformed' do
          let :config do
            super().merge('template_url' => 's5://templates-${AWS_REGION}/some/prefix/${TEMPLATE_NAME}-${TIMESTAMP}.json')
          end

          it 'raises an error' do
            expect { compiler.validate_template('stack', large_template) }.to raise_error(described_class::ValidationError, 'Malformed template URL: "s5://templates-${AWS_REGION}/some/prefix/${TEMPLATE_NAME}-${TIMESTAMP}.json"')
          end
        end

        context 'and no template bucket has been specified' do
          let :config do
            super().tap do |c|
              c.delete('template_url')
            end
          end

          it 'raises an error' do
            expect { compiler.validate_template('stack', large_template) }.to raise_error(described_class::ValidationError, 'Unable to validate template: it is larger than 51200 bytes and no template URL has been configured')
          end
        end
      end

      context 'when the compiled template is larger than 460800 bytes' do
        let :large_template do
          '0' * 460801
        end

        it 'raises a template error' do
          expect { compiler.validate_template('stack', large_template) }.to raise_error(described_class::TemplateError, 'Compiled template is too large: 460801 bytes > 460800')
        end
      end
    end
  end
end
