require "http/server"
require "json"
require "mutex"

module CommandRunner
  module Middleware
    class ErrorHandler
      include HTTP::Handler

      def call(context : HTTP::Server::Context) : Nil
        call_next(context)
      rescue ex : ValidationError
        respond_error(context, 400, ex.message || "validation error")
      rescue ex : WorkloadNotFound
        respond_error(context, 404, ex.message || "not found")
      rescue ex : Exception
        Log.error { "unhandled exception: #{ex.class}: #{ex.message}" }
        Log.debug { ex.backtrace.try(&.join("\n")) }
        respond_error(context, 500, "internal server error")
      end

      private def respond_error(context : HTTP::Server::Context, status : Int32, message : String) : Nil
        return if context.response.closed?
        return if context.response.headers_written?

        context.response.status_code = status
        context.response.content_type = "application/json"
        context.response.print({"error" => message}.to_json)
      rescue IO::Error
      end
    end

    class RequestSize
      include HTTP::Handler

      def initialize(@max_bytes : Int32)
      end

      def call(context : HTTP::Server::Context) : Nil
        if content_length = context.request.content_length
          if content_length > @max_bytes
            context.response.status_code = 413
            context.response.content_type = "application/json"
            context.response.print({"error" => "request body too large"}.to_json)
            return
          end
        end

        call_next(context)
      end
    end

    class AuditLog
      include HTTP::Handler

      def call(context : HTTP::Server::Context) : Nil
        start = Time.instant
        call_next(context)
        duration = (Time.instant - start).total_milliseconds.to_i64

        cn = context.client_cn || "unknown"
        Log.info do
          "#{context.request.method} #{context.request.path} " \
          "-> #{context.response.status_code} (#{duration}ms) " \
          "client=#{cn} remote=#{context.request.remote_address}"
        end
      end
    end

    class RateLimit
      include HTTP::Handler

      @buckets : Hash(String, Array(Time::Instant))
      @mutex : Mutex

      def initialize(@max_per_minute : Int32)
        @buckets = {} of String => Array(Time::Instant)
        @mutex = Mutex.new
      end

      def call(context : HTTP::Server::Context) : Nil
        cn = context.client_cn
        unless cn
          call_next(context)
          return
        end

        if rate_limited?(cn)
          Log.warn { "rate limited: #{cn}" }
          context.response.status_code = 429
          context.response.content_type = "application/json"
          context.response.print({"error" => "rate limited"}.to_json)
          return
        end

        call_next(context)
      end

      private def rate_limited?(cn : String) : Bool
        @mutex.synchronize do
          now = Time.instant
          window = 60.seconds

          bucket = @buckets[cn] ||= [] of Time::Instant
          bucket.reject! { |t| t < (now - window) }

          if bucket.size >= @max_per_minute
            true
          else
            bucket << now
            false
          end
        end
      end
    end
  end
end
