require "./config"
require "./tls"
require "./workloads"
require "./executor"
require "./auth"
require "./middleware"
require "./router"

module CommandRunner
  VERSION = "0.1.0"
  Log     = ::Log.for("command_runner")

  class Error < Exception; end

  class ValidationError < Error; end

  class WorkloadNotFound < Error; end

  def self.run(argv : Array(String)) : Nil
    config_path = "config.yml"

    OptionParser.parse(argv) do |parser|
      parser.banner = "Usage: command_runner --config CONFIG_PATH"
      parser.on("-c", "--config PATH", "Path to config file (default: config.yml)") do |path|
        config_path = path
      end
      parser.on("-h", "--help", "Show this help") do
        puts parser
        exit
      end
      parser.invalid_option { |opt| abort "Invalid option: #{opt}" }
    end

    config = Config.load(config_path)
    tls_context = TLS.build_context(config.tls)
    registry = WorkloadRegistry.new(config.workloads, config.limits.default_timeout)
    executor = Executor.new(config.limits.output_bytes)
    router = Router.new(registry, executor)

    handlers = [
      Middleware::ErrorHandler.new,
      Middleware::RequestSize.new(config.limits.request_body_bytes),
      Middleware::AuditLog.new,
      AuthHandler.new(config.allowed_clients.to_set),
      Middleware::RateLimit.new(config.limits.rate_per_minute),
      router,
    ] of HTTP::Handler

    server = HTTP::Server.new(handlers)

    host, port = parse_listen(config.listen)
    address = server.bind_tls(host, port, tls_context)

    Log.info { "command_runner #{VERSION} listening on https://#{address} (mTLS enforced)" }
    Log.info { "#{registry.size} workloads registered, #{config.allowed_clients.size} clients allowed" }

    Process.on_terminate do |reason|
      Log.info { "shutting down... (#{reason})" }
      server.close
    end

    server.listen
  end

  private def self.parse_listen(listen : String) : {String, Int32}
    parts = listen.split(':')
    raise "Invalid listen address: #{listen} (expected host:port)" unless parts.size == 2
    {parts[0], parts[1].to_i}
  end
end

require "option_parser"
require "log"
require "http/server"
