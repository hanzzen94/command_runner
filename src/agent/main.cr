require "option_parser"
require "../command_runner"
require "../config"
require "./agent"

module CommandRunner
  def self.run_agent(argv : Array(String)) : Nil
    config_path = "config.agent.yml"

    OptionParser.parse(argv) do |parser|
      parser.banner = "Usage: command_runner --config CONFIG_PATH"
      parser.on("-c", "--config PATH", "Path to agent config file (default: config.agent.yml)") do |path|
        config_path = path
      end
      parser.on("-h", "--help", "Show this help") do
        puts parser
        exit
      end
      parser.invalid_option { |opt| abort "Invalid option: #{opt}" }
    end

    config = AgentConfig.load(config_path)
    agent = Agent.new(config)

    Process.on_terminate do |reason|
      Log.info { "shutting down... (#{reason})" }
      agent.stop
    end

    agent.start
  end
end

CommandRunner.run_agent(ARGV)
