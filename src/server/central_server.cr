require "http/server"
require "json"
require "pg"
require "../config"
require "../amqp"
require "../task"
require "../tls"
require "./auth"
require "./middleware"
require "./router"

module CommandRunner
  class Database
    @db : DB::Database

    def initialize(config : DatabaseConfig)
      @db = DB.open(config.url)
      @results_limit = config.results_limit
      migrate
    end

    def migrate : Nil
      @db.exec <<-SQL
        CREATE TABLE IF NOT EXISTS tasks (
          task_id           TEXT PRIMARY KEY,
          server_cloud_id   TEXT NOT NULL,
          customer_id       TEXT NOT NULL,
          workload          TEXT NOT NULL,
          params            JSONB NOT NULL DEFAULT '{}',
          submitted_at      TIMESTAMPTZ NOT NULL,
          submitted_by      TEXT NOT NULL DEFAULT '',
          status            TEXT NOT NULL DEFAULT 'queued'
        )
      SQL

      @db.exec <<-SQL
        CREATE TABLE IF NOT EXISTS task_results (
          task_id           TEXT PRIMARY KEY REFERENCES tasks(task_id) ON DELETE CASCADE,
          server_cloud_id   TEXT NOT NULL,
          customer_id       TEXT NOT NULL,
          exit_code         INTEGER NOT NULL,
          stdout            TEXT NOT NULL DEFAULT '',
          stderr            TEXT NOT NULL DEFAULT '',
          truncated         BOOLEAN NOT NULL DEFAULT false,
          timed_out         BOOLEAN NOT NULL DEFAULT false,
          duration_us       BIGINT NOT NULL,
          executed_at       TEXT NOT NULL,
          error             TEXT
        )
      SQL

      @db.exec "CREATE INDEX IF NOT EXISTS idx_tasks_customer_id ON tasks(customer_id)"
      @db.exec "CREATE INDEX IF NOT EXISTS idx_task_results_customer_id ON task_results(customer_id)"
      @db.exec "CREATE INDEX IF NOT EXISTS idx_task_results_executed_at ON task_results(executed_at DESC)"
    end

    def store_task(task : Task) : Nil
      @db.exec(
        "INSERT INTO tasks (task_id, server_cloud_id, customer_id, workload, params, submitted_at, submitted_by) VALUES ($1, $2, $3, $4, $5, $6, $7)",
        task.task_id, task.server_cloud_id, task.customer_id, task.workload, task.params.to_json, task.submitted_at, task.submitted_by
      )
    end

    def store_result(result : TaskResult) : Nil
      @db.transaction do |tx|
        tx.connection.exec(
          <<-SQL,
          INSERT INTO task_results (task_id, server_cloud_id, customer_id, exit_code, stdout, stderr, truncated, timed_out, duration_us, executed_at, error)
          VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11)
          ON CONFLICT (task_id) DO UPDATE SET
            server_cloud_id = EXCLUDED.server_cloud_id,
            customer_id = EXCLUDED.customer_id,
            exit_code = EXCLUDED.exit_code,
            stdout = EXCLUDED.stdout,
            stderr = EXCLUDED.stderr,
            truncated = EXCLUDED.truncated,
            timed_out = EXCLUDED.timed_out,
            duration_us = EXCLUDED.duration_us,
            executed_at = EXCLUDED.executed_at,
            error = EXCLUDED.error
          SQL
          result.task_id, result.server_cloud_id, result.customer_id, result.exit_code, result.stdout,
          result.stderr, result.truncated, result.timed_out, result.duration_us,
          result.executed_at, result.error
        )
        tx.connection.exec(
          "UPDATE tasks SET status = 'completed' WHERE task_id = $1",
          result.task_id
        )
      end
    end

    def get_result(task_id : String) : TaskResult?
      @db.query_one?(
        "SELECT task_id, server_cloud_id, customer_id, exit_code, stdout, stderr, truncated, timed_out, duration_us, executed_at, error FROM task_results WHERE task_id = $1",
        task_id
      ) do |rs|
        TaskResult.new(
          task_id: rs.read(String),
          server_cloud_id: rs.read(String),
          customer_id: rs.read(String),
          exit_code: rs.read(Int32),
          stdout: rs.read(String),
          stderr: rs.read(String),
          truncated: rs.read(Bool),
          timed_out: rs.read(Bool),
          duration_us: rs.read(Int64),
          executed_at: rs.read(String),
          error: rs.read(String?),
        )
      end
    end

    def list_results(limit : Int32? = nil, offset : Int32 = 0, customer_id : String? = nil) : Array(TaskResult)
      lim = limit || @results_limit
      results = [] of TaskResult

      if customer_id
        @db.query(
          "SELECT task_id, server_cloud_id, customer_id, exit_code, stdout, stderr, truncated, timed_out, duration_us, executed_at, error FROM task_results WHERE customer_id = $1 ORDER BY executed_at DESC LIMIT $2 OFFSET $3",
          customer_id, lim, offset
        ) do |rs|
          rs.each do
            results << TaskResult.new(
              task_id: rs.read(String),
              server_cloud_id: rs.read(String),
              customer_id: rs.read(String),
              exit_code: rs.read(Int32),
              stdout: rs.read(String),
              stderr: rs.read(String),
              truncated: rs.read(Bool),
              timed_out: rs.read(Bool),
              duration_us: rs.read(Int64),
              executed_at: rs.read(String),
              error: rs.read(String?),
            )
          end
        end
      else
        @db.query(
          "SELECT task_id, server_cloud_id, customer_id, exit_code, stdout, stderr, truncated, timed_out, duration_us, executed_at, error FROM task_results ORDER BY executed_at DESC LIMIT $1 OFFSET $2",
          lim, offset
        ) do |rs|
          rs.each do
            results << TaskResult.new(
              task_id: rs.read(String),
              server_cloud_id: rs.read(String),
              customer_id: rs.read(String),
              exit_code: rs.read(Int32),
              stdout: rs.read(String),
              stderr: rs.read(String),
              truncated: rs.read(Bool),
              timed_out: rs.read(Bool),
              duration_us: rs.read(Int64),
              executed_at: rs.read(String),
              error: rs.read(String?),
            )
          end
        end
      end

      results
    end

    def close : Nil
      @db.close
    end
  end

  class CentralServer
    @server : HTTP::Server?
    @amqp : AmqpClient
    @db : Database
    @running = false

    getter config : ServerConfig

    def initialize(@config : ServerConfig)
      @amqp = AmqpClient.new(@config.amqp)
      @db = init_database(@config.results)
    end

    private def init_database(config : DatabaseConfig) : Database
      loop do
        begin
          return Database.new(config)
        rescue ex : Exception
          Log.error { "Database connection failed: #{ex.message}, retrying in 5s..." }
          sleep 5.seconds
        end
      end
    end

    def start : Nil
      @running = true

      loop do
        begin
          @amqp.connect
          break
        rescue ex : Exception
          Log.error { "AMQP connection failed: #{ex.message}, retrying in 5s..." }
          sleep 5.seconds
        end
      end

      spawn consume_results_loop

      tls_context = TLS.build_context(@config.tls)
      router = ServerRouter.new(@amqp, @db)

      handlers = [
        Middleware::ErrorHandler.new,
        Middleware::RequestSize.new(@config.limits.request_body_bytes),
        Middleware::AuditLog.new,
        AuthHandler.new(@config.allowed_clients.to_set),
        Middleware::RateLimit.new(@config.limits.rate_per_minute),
        router,
      ] of HTTP::Handler

      server = HTTP::Server.new(handlers)
      @server = server

      host, port = parse_listen(@config.listen)
      address = server.bind_tls(host, port, tls_context)

      Log.info { "central_server #{VERSION} listening on https://#{address} (mTLS enforced)" }
      Log.info { "#{@config.allowed_clients.size} clients allowed" }

      Process.on_terminate do |reason|
        Log.info { "shutting down... (#{reason})" }
        @running = false
        server.close
        @amqp.close
        @db.close
      end

      server.listen
    end

    private def consume_results_loop : Nil
      loop do
        break unless @running
        begin
          @amqp.consume_results do |result|
            @db.store_result(result)
            Log.info { "result stored: task=#{result.task_id} server_cloud_id=#{result.server_cloud_id} exit_code=#{result.exit_code}" }
          end
        rescue ex : Exception
          Log.error { "results consumer error: #{ex.class}: #{ex.message}" }
          sleep 5.seconds if @running
        end
      end
    end

    private def parse_listen(listen : String) : {String, Int32}
      parts = listen.split(':')
      raise "Invalid listen address: #{listen} (expected host:port)" unless parts.size == 2
      {parts[0], parts[1].to_i}
    end
  end
end
