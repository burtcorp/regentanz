# Regentanz examples

This directory contains an example templates and an example custom resources. The template is for a made up application called SuperDuper that is hosted on EC2 and runs in an auto scaling group.

## Compiling the template

Use the `compile` command to compile the `super_duper` template into CloudFormation JSON:

```shell
$ ../bin/regentanz compile templates/super_duper > build/super_duper.json
```

The compiler uses the CloudFormation API to validate the template so you will need to either have the `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, and `AWS_DEFAULT_REGION` environment variables set, or any of the other standard ways of configuring the AWS SDK with credentials.

### Template contents

The template `super_duper` contains an auto scaling group and everything else that is needed to launch instances into it; a launch configuration, a security group, an instance profile, and an IAM role.

The auto scaling group, launch configuration, and security group are created through a custom resource called `Regentanz::Resources::App` that is defined in `lib/regentanz/resources/app.rb`. The compiler finds this custom resource because of the file `.regentanz.yml` that contains a pointer to the `lib` directory.

The custom resource also adds parameters that are merged with the parameters defined in `parameters.yml`. It also adds metadata to the template that groups the parameters into a group called "SuperDuper parameters" (parameter groups is mainly a visual aid in the CloudFormation UI).

When you compile the template you can see what the custom resource generates. The resources `SuperDuperAsg`, `SuperDuperLc`, and `SuperDuperSg` are generated from `super_duper/resources/super_duper.yml`, as well as the `SuperDuperCount`, `SuperDuperInstanceType`, and `SuperDuperAmi` parameters.

The custom resource has properties that correspond directly to properties on the built-in resources it creates, like `VpcId` that is set on the security group, and `IamInstanceProfile` that is set on the launch configuration, but also `Name` that is used in an expression that sets the "Name" tag of the auto scaling group and security group. The expressions prefix the name by the `Environment` parameter and suffixes it with "asg" and "sg", respectively.
