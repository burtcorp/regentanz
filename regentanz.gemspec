$: << File.expand_path('../lib', __FILE__)

require 'regentanz/version'

Gem::Specification.new do |s|
  s.name = 'regentanz'
  s.version = Regentanz::VERSION.dup
  s.authors = ['Burt Platform Team']
  s.email = ['theo@burtcorp.com', 'munkby@burtcorp.com', 'david@burtcorp.com']
  s.homepage = 'http://github.com/burtcorp/regentanz'
  s.summary = %q{Template preprocessor and compiler for CloudFormation}
  s.description = %q{Regentanz is a template preprocessor and compiler that makes it easier to work with CloudFormation}
  s.license = 'BSD 3-Clause'

  s.files = Dir['lib/**/*.rb', 'README.md', '.yardopts']
  s.test_files = Dir['spec/**/*.rb']
  s.executables = Dir['bin/*'].map { |f| File.basename(f) }
  s.require_paths = %w(lib)

  s.add_runtime_dependency 'aws-sdk-s3', '~> 1'
  s.add_runtime_dependency 'aws-sdk-cloudformation', '~> 1'

  s.platform = Gem::Platform::RUBY
  s.required_ruby_version = '>= 2.0.0'
end
