require 'regentanz'
require 'regentanz/cli/common'

class Main
  include Regentanz::Cli::Common

  def initialize
    @compiler = Regentanz::TemplateCompiler.new
  end

  def run(args)
    load_config
    stack_path = args.first
    template = @compiler.compile_from_path(stack_path)
    template_json = JSON.pretty_generate(template)
    if template_json.bytesize >= 51200
      template_json = JSON.generate(template)
    end
    @compiler.validate_template(stack_path, template_json)
    puts(template_json)
    0
  rescue Regentanz::Error => e
    $stderr.puts(e.message)
    1
  end
end
