require "option_parser"
require "../command_runner"
require "../config"
require "./central_server"

module CommandRunner
  def self.run_server(argv : Array(String)) : Nil
    config_path = "config.server.yml"

    OptionParser.parse(argv) do |parser|
      parser.banner = "Usage: central_server --config CONFIG_PATH"
      parser.on("-c", "--config PATH", "Path to server config file (default: config.server.yml)") do |path|
        config_path = path
      end
      parser.on("-h", "--help", "Show this help") do
        puts parser
        exit
      end
      parser.invalid_option { |opt| abort "Invalid option: #{opt}" }
    end

    config = ServerConfig.load(config_path)
    server = CentralServer.new(config)

    server.start
  end
end

CommandRunner.run_server(ARGV)
