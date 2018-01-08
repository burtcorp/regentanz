require 'json'
require 'yaml'
require 'aws-sdk-s3'
require 'aws-sdk-cloudformation'

module Regentanz
  Error = Class.new(StandardError)
end

require 'regentanz/template_compiler'
