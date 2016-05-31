# encoding: utf-8

require 'spec_helper'

module Regentanz
  describe TemplateCompiler do
    let :compiler do
      described_class.new(cloud_formation_client: cf_client)
    end

    let :cf_client do
      double(:cf_client)
    end

    describe '#compile_template' do
      let :resources do
        {
          'core/ec2_instance.json' => {
            'Type' => 'AWS::EC2::Instance',
            'Properties' => {
              'ImageId' => {'Fn::FindInMap' => ['Ami', 'amzn-ami-2016.03.1', 'hvm']},
            }
          }
        }
      end

      let :parameters do
        {
          'X' => {
            'Type' => 'Number',
            'Default' => 1,
          },
          'Y' => {
            'Type' => 'Number',
            'Default' => 1,
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
        expect(template['Resources'].keys).to eq(%w[CoreEc2Instance])
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

      context 'with parameter labels' do
        it 'removes the Label key from parameters' do
          parameters['X']['Label'] = 'The X'
          expect(template['Parameters']['X']).not_to include('Label')
        end

        it 'adds parameter labels to the interface metadata' do
          parameters['X']['Label'] = 'The X'
          expect(template['Metadata']['AWS::CloudFormation::Interface']['ParameterLabels']).to eq('X' => {'default' => 'The X'})
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

        it 'removes the group parameters from the output' do
          expect(template['Parameters']).not_to include('Group')
        end

        it 'lifts the grouped parameters to the top level' do
          expect(template['Parameters'].keys).to eq(%w[X Y Nested])
        end

        it 'lifts the grouped parameters to the top level' do
          expect(template['Parameters'].keys).to eq(%w[X Y Nested])
        end

        it 'adds parameter groups to the interface metadata' do
          expect(template['Metadata']['AWS::CloudFormation::Interface']['ParameterGroups']).to eq([{'Label' => {'default' => 'Group'}, 'Parameters' => ['Nested']}])
        end
      end

      context 'with a custom resource type' do
        let :resources do
          super().merge(
            'core/test.json' => {
              'Type' => 'Regentanz::Resources::BucketAndPolicy',
              'Properties' => {
                'Name' => {'Ref' => 'CoreTestBucketName'},
              }
            }
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
          expect(template['Parameters']).to include('X')
        end

        it 'adds mappings from the compiled resource' do
          expect(template['Mappings']).to include('Prefix')
        end

        it 'keeps parameters from outside the resource' do
          expect(template['Mappings']).to include('Version')
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

          it 'includes the values from the compiled resource', aggregate_failures: true do
            expect(template['Resources']).to include('CoreTestAsg', 'CoreTestLc')
            expect(template['Parameters']).to include('CoreTestMinSize')
            expect(template['Conditions']).to include('CoreTestUseSpot')
            expect(template['Mappings']).to include('Ami')
            expect(template).not_to include('Outputs')
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
        File.write('template/conditions.json', '{"Staging":{"Fn:Equals":[{"Ref":"Environment"},"staging"]}}')
        File.write('template/outputs.json', '{"VolumeId":{"Value":{"Ref":"Volume"}}}')
        expect(template['Parameters'].keys).to eq(%w[Parameter])
        expect(template['Mappings'].keys).to eq(%w[Mapping])
        expect(template['Conditions'].keys).to eq(%w[Staging])
        expect(template['Outputs'].keys).to eq(%w[VolumeId])
      end

      it 'loads parameters, mappings, conditions, outputs from YAML files', aggregate_failures: true do
        File.write('template/parameters.yaml', 'Parameter: {Type: Number}')
        File.write('template/mappings.yaml', 'Mapping: {A: {B: C}}')
        File.write('template/conditions.yml', 'Staging: {"Fn:Equals": [{Ref: Environment}, staging]}')
        File.write('template/outputs.yml', 'VolumeId: {Value: {Ref: Volume}}')
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
    end

    describe '#validate_template' do
      it 'uses the CloudFormation API to validate the template' do
        allow(cf_client).to receive(:validate_template)
        compiler.validate_template('my-template')
        expect(cf_client).to have_received(:validate_template).with(template_body: 'my-template')
      end

      it 'produces a validation error when template is invalid' do
        allow(cf_client).to receive(:validate_template).and_raise(Aws::CloudFormation::Errors::ValidationError.new(nil, 'boork'))
        expect { compiler.validate_template('my-template') }.to raise_error(described_class::ValidationError, 'Invalid template: boork')
      end

      it 'produces a validation error for credentials errors' do
        allow(cf_client).to receive(:validate_template).and_raise(Aws::Errors::MissingCredentialsError, 'boork')
        expect { compiler.validate_template('my-template') }.to raise_error(described_class::ValidationError, 'Validation requires AWS credentials')
      end
    end
  end
end

module Regentanz
  module Resources
    class BucketAndPolicy
      def compile(name, resource)
        result = {:parameters => {}, :resources => {}, :outputs => {}, :mappings => {}}
        result[:parameters]['BucketName'] = {'Type' => 'String'}
        result[:resources][name + 'Bucket'] = {}
        result[:resources][name + 'Policy'] = {}
        result[:mappings]['Prefix'] = {'production' => 'prod-', 'test' => 'test-'}
        result
      end
    end
  end
end
