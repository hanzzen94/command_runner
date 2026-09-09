require "http/server"
require "json"

module CommandRunner
  struct RunRequest
    include JSON::Serializable

    getter params : Hash(String, String) = {} of String => String
  end

  struct WorkloadInfo
    include JSON::Serializable

    getter name : String
    getter params : Array(String)

    def initialize(@name : String, @params : Array(String))
    end
  end

  class Router
    include HTTP::Handler

    def initialize(@registry : WorkloadRegistry, @executor : Executor)
    end

    def call(context : HTTP::Server::Context) : Nil
      path = context.request.path || "/"
      method = context.request.method

      case {method, path}
      when {"GET", "/workloads"}
        handle_list(context)
      when {"POST", path}
        if match = path.match(/^\/workloads\/([^\/]+)\/run$/)
          handle_run(context, match[1])
        else
          respond_not_found(context)
        end
      else
        respond_not_found(context)
      end
    end

    private def handle_list(context : HTTP::Server::Context) : Nil
      cn = context.client_cn || ""
      workloads = @registry.visible_to(cn)

      info = workloads.map do |w|
        WorkloadInfo.new(w.name, w.params.map(&.name))
      end

      context.response.content_type = "application/json"
      context.response.print(info.to_json)
    end

    private def handle_run(context : HTTP::Server::Context, name : String) : Nil
      workload = @registry.find(name)
      raise WorkloadNotFound.new("workload not found: #{name}") unless workload

      cn = context.client_cn || ""
      unless workload.allowed?(cn)
        Log.warn { "workload access denied: client=#{cn} workload=#{name}" }
        context.response.status_code = 403
        context.response.content_type = "application/json"
        context.response.print({"error" => "not authorized for this workload"}.to_json)
        return
      end

      body = context.request.body.try(&.gets_to_end) || ""
      request = begin
        RunRequest.from_json(body.empty? ? "{}" : body)
      rescue ex : JSON::ParseException
        raise ValidationError.new("invalid JSON: #{ex.message}")
      end

      result = @executor.run(workload, request.params)

      context.response.status_code = 200
      context.response.content_type = "application/json"
      context.response.print(result.to_json)
    end

    private def respond_not_found(context : HTTP::Server::Context) : Nil
      context.response.status_code = 404
      context.response.content_type = "application/json"
      context.response.print({"error" => "not found"}.to_json)
    end
  end
end
