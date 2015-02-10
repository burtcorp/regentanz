require 'json'
require 'yaml'
require 'aws-sdk-core'

module Regentanz
  Error = Class.new(StandardError)
end

require_relative 'regentanz/template_compiler'
