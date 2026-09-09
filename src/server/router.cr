require "http/server"
require "json"
require "../task"

module CommandRunner
  struct TaskRequest
    include JSON::Serializable

    getter agent_id : String
    getter workload : String
    getter params : Hash(String, String) = {} of String => String
  end

  class ServerRouter
    include HTTP::Handler

    def initialize(@amqp : AmqpClient, @db : Database)
    end

    def call(context : HTTP::Server::Context) : Nil
      path = context.request.path || "/"
      method = context.request.method

      case {method, path}
      when {"GET", "/health"}
        handle_health(context)
      when {"POST", "/tasks"}
        handle_submit_task(context)
      when {"GET", "/results"}
        handle_list_results(context)
      when {"GET", path}
        if match = path.match(/^\/results\/([^\/]+)$/)
          handle_get_result(context, match[1])
        else
          respond_not_found(context)
        end
      else
        respond_not_found(context)
      end
    end

    private def handle_health(context : HTTP::Server::Context) : Nil
      context.response.content_type = "application/json"
      context.response.print({"status" => "ok"}.to_json)
    end

    private def handle_submit_task(context : HTTP::Server::Context) : Nil
      body = context.request.body.try(&.gets_to_end) || ""
      request = begin
        TaskRequest.from_json(body.empty? ? "{}" : body)
      rescue ex : JSON::ParseException
        raise ValidationError.new("invalid JSON: #{ex.message}")
      end

      cn = context.client_cn || "unknown"
      task = Task.new(request.agent_id, request.workload, request.params, cn)

      published = @amqp.publish_task(task)

      unless published
        context.response.status_code = 503
        context.response.content_type = "application/json"
        context.response.print({"error" => "failed to publish task"}.to_json)
        return
      end

      @db.store_task(task)

      receipt = TaskReceipt.new(task.task_id, "queued")

      Log.info { "task submitted: #{task.task_id} agent=#{task.agent_id} workload=#{task.workload} by=#{cn}" }

      context.response.status_code = 201
      context.response.content_type = "application/json"
      context.response.print(receipt.to_json)
    end

    private def handle_list_results(context : HTTP::Server::Context) : Nil
      params = context.request.query_params
      limit = params["limit"]?.try(&.to_i?) || nil
      offset = params["offset"]?.try(&.to_i?) || 0

      results = @db.list_results(limit: limit, offset: offset)
      context.response.content_type = "application/json"
      context.response.print(results.to_json)
    end

    private def handle_get_result(context : HTTP::Server::Context, task_id : String) : Nil
      result = @db.get_result(task_id)

      unless result
        context.response.status_code = 404
        context.response.content_type = "application/json"
        context.response.print({"error" => "result not found"}.to_json)
        return
      end

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
