# Regentanz

[![Build Status](https://travis-ci.org/burtcorp/regentanz.png?branch=master)](https://travis-ci.org/burtcorp/regentanz)

_If you're reading this on GitHub, please note that this is the readme for the development version and that some features described here might not yet have been released. You can find the readme for a specific version via the release tags ([here is an example](https://github.com/burtcorp/regentanz/tree/1.0.0))._

Regentanz is a compiler and preprocessor for CloudFormation templates. It allows you to split up a template into one file per resource, and also build custom resources that can decrease the complexity of templates.

## Installation

Install it on the command line:

```shell
$ gem install regentanz
```

or add it to your `Gemfile`:

```ruby
gem 'regentanz'
```

## How to build and run the tests

The best place to see how to build and run the tests is to look at the `.travis.yml` file, but if you just want to get going run:

```shell
$ bundle
$ rake
```

## Usage

To compile a template you use the `regentanz` command like this:

```shell
$ regentanz compile path/to/template > path/to/compiled/template.json
```

The compiler will validate the final template with CloudFormation, so you will need to run it with AWS credentials that permit `cloudformation:ValidateTemplate`.

### Anatomy of a template

Just like a CloudFormation template, a Regentanz template consists of conditions, mappings, outputs, parameters, and resources. In contrast with CloudFormation these are not properties of one big JSON or YAML document, but exists as separate files in a directory structure. Each resource has its own file, and there is one file each for conditions, mappings, and parameters. If the template doesn't need conditions, mappings, or parameters these files can be left out.

The Regentanz compiler will take a directory and output a CloudFormation template in JSON format that can be used with CloudFormation.

#### Example

Say you have an application with an auto scaling group, launch configuration, security group, an instance profile, and an IAM role for the instance profile. In a regular CloudFormation template you would declare five different resources in one big JSON or YAML file, but in Regentanz you would instead keep these in five separate files, something like this:

```
my_application/
  resources/
    auto_scaling_group.yml
    iam_role.yml
    instance_profile.yml
    launch_configuration.yml
    security_group.yml
```

You're free to name the files whatever you want, and you can put them in subdirectories too. This is an alternative way to structure the same template:

```
my_application/
  resources/
    iam/
      role.yml
      instance_profile.yml
    asg.yml
    lc.yml
    sg.yml
```

If you have conditions, mappings, outputs, or parameters you put these in files at the top level:

my_application/
  resources/
    iam/
      role.yml
      instance_profile.yml
    asg.yml
    lc.yml
    sg.yml
  conditions.yml
  mappings.yml
  outputs.yml
  parameters.yml
```

You can use JSON or YAML for your files, and mix between these in the same template.

The contents of the files is the same thing you would put in a CloudFormation template. In other words, if your CloudFormation looks something like this:

```yaml
Parameters:
  ServerCount:
    Type: Number
    Default: 2
    MinValue: 0

Resources:
  Asg:
    Type: AWS::EC2::AutoScalingGroup
    Properties:
      DesiredCapacity: !Ref ServerCount
      # …
  Lc:
    Type: AWS::EC2::LaunchConfiguration
    Properties:
      # …
```

You would put the parameters in `parameters.yml`:

```yaml
Parameters:
  ServerCount:
    Type: Number
    Default: 2
    MinValue: 0
```

The auto scaling group resource in `resources/asg.yml`:

```yaml
Type: AWS::EC2::AutoScalingGroup
Properties:
  DesiredCapacity: {Ref: DesiredCapacity}
  # …
```

Unfortunately CloudFormation's YAML syntax for intrinsic functions (e.g. `!Ref`) is not supported, you have to convert it to YAML/JSON (e.g. `{Ref: …}`), like above.

The launch configuration resource would go in a file called `resources/lc.yml`:

```yaml
Type: AWS::EC2::LaunchConfiguration
Properties:
  # …
```

And when you compile this with the Regentanz compiler you would get the same CloudFormation template back, but in JSON format.

### Resource references

The Regentanz compiler will generate resource names based on the relative paths of the files in the template. Currently the scheme is to take the path relative to the root of the template and create a `CamelCase` with no underscores or slashes. You should however not rely on this convention since it could change in the future. Instead you should use two macros provided by Regentanz that work similar to CloudFormation's `Ref` function.

Wherever you would have used `Ref` in CloudFormation you should use `ResolveRef`, and use the relative path, minus file ending as argument. In the template in the example above you could for example refer to the IAM role with `{ResolveRef: iam/role}`, and the auto scaling group as `{ResolveRef: asg}`.

In places where you in CloudFormation would have used the name of a resource directly you should use `ResolveName`. For example `{ResolveName: iam/role}` and `{ResolveName: asg}`. Almost the only place you will need `ResolveName` is in `GetAtt`.

Continuing on the example above the auto scaling group needs to refer to the launch configuration. Using `ResolveRef` that would look like this:

```yaml
Type: AWS::EC2::AutoScalingGroup
Properties:
  LaunchConfigurationName: {ResolveRef: asg}
  # …
```

## Custom Resources

If you've written a lot of CloudFormation templates you probably feel like you're constantly repeating yourself. The same patterns appear again and again in multiple templates. To help with this Regentanz lets you write custom resources that can be used in templates and that generate other resources, parameters, mappings, etc. when compiled.

A custom resource is a Ruby class that lives in the `Regentanz::Resources` module that has a `#compile` method that returns a partial template.

### Anatomy of a custom resource

Custom resources will be instantiated by the template compiler and their `#compile` method will be called with the name of the resource and the resource template. The result of this call must be a "template fragment", which is a hash with a `:resources` key, and optionally `:conditions`, `:mappings`, `:outputs`, and `:parameters`. Each of these must be (when specified) a hash that looks like the corresponding CloudFormation structure

Say you used a custom resource like the following, in a file with the relative path `app/sg.yml`

```yaml
Type: Regentanz::Resources::MySpecialSecurityGroup
Properties:
  Name: special-sg
  PortsOpenToEveryone:
    - 22
    - 80
```

The compiler will, conceptually, do this (`template_fragment` is a the contents of the file):

```ruby
resource = Regentanz::Resources::MyCustomResource
result = resource.compile('AppSg', template_fragment)
```

It will then take the result and merge it with the rest of the template.

This is how you could implement `MySpecialSecurityGroup`:

```ruby
class Regentanz::Resources::MyCustomResource
  def compile(name, template)
    ingress_rules = template['Properties']['PortsOpenToEveryone'].map do |port|
      {'IpProtocol' => 'tcp', 'FromPort' => port, 'ToPort' => port, 'CidrIp' => '0.0.0.0/0'}
    end
    {
      :resources => {
        name => {
          'Type' => 'AWS::EC2::SecurityGroup',
          'Properties' => {
            'GroupName' => properties['Name'],
            'SecurityGroupIngress' => ingress_rules
          }
        }
      }
    }
  end
end
```

You are free to ignore the `name` parameter, but it is strongly recommended that you use it. It is the name Regentanz has generated from the relative path of the file the resource is declared in, so ignoring it will make it harder and more confusing to refer to the resource the custom resource generates. If you generate more than one resource in your template it is recommended that you use `name` as a prefix. For example if you generate an auto scaling group and a launch configuration from the a custom resource generating resources with names like `"#{name}Asg"`, and `"#{name}Lc"` will make it possible to do `{ResolveRef: my_resource/asg}` in another resource.

If the template fragment returned by `#compile` contains `ResolveRef` or `ResolveName` these will be resolved as expected.

### Adding custom resources to the load path

Custom resources must be available on the load path when the template compiler runs. The name of the file must also follow the standard Ruby naming convention, i.e. a resource called `Regentanz::Resources::MyCustomResource` must be declared in a file with the path `regentanz/resources/my_custom_resource.rb`, so that the compiler knows which file to load.

This can be achieved by manipulating environment variables like `RUBYLIB`, or by packaging your custom resources as a gem, but in most cases the easiest way is to add a config file that tells the template compiler how to modify the load path to be able to load your custom resources.

You can add a file called `.regentanz.yml` in any parent directory of the directory where you run the compiler. In the file you put a list of paths to add to the Ruby load path:

```yaml
load_path:
  - path/to/resources
  - /an/absolute/path
```

Relative paths will be resolved relative to the config file.

The config file above will allow the template compiler to find custom resources in files such as `path/to/resources/regentanz/resources/my_custom_resource.rb` (relative to the config file) and `/an/absolute/path/regentanz/resources/my_custom_resource.rb`.

## Limitations

Regentanz unfortunately does not support CloudFormation's YAML syntax for intrinsic functions.

# Copyright

© 2015-2018 Burt AB, see LICENSE.txt (BSD 3-Clause).
