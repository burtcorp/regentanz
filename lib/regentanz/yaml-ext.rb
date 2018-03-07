# frozen_string_literal: true
require 'yaml'

module YAML
  add_domain_type('regentanz', 'GetAtt') do |_, value|
    {'Fn::GetAtt' => value.to_s.split('.')}
  end
  %w[Ref ResolveRef].each do |name|
    add_domain_type('regentanz', name) do |tag, value|
      {name => value}
    end
  end
  %w[FindInMap GetAZs ImportValue Join Select Split Sub].each do |name|
    add_domain_type('regentanz', name) do |tag, value|
      {['Fn', name].join('::') => value}
    end
  end
end
