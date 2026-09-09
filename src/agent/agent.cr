require "../config"
require "../amqp"
require "../task"
require "./workloads"
require "./executor"

module CommandRunner
  class Agent
    @running = false

    getter agent_id : String
    getter registry : WorkloadRegistry
    getter executor : Executor
    getter amqp : AmqpClient

    def initialize(config : AgentConfig)
      @agent_id = config.agent_id
      @registry = WorkloadRegistry.new(config.workloads, config.limits.default_timeout)
      @executor = Executor.new(config.limits.output_bytes)
      @amqp = AmqpClient.new(config.amqp, agent_id: config.agent_id)
    end

    def start : Nil
      @running = true
      connect_with_retry

      Log.info { "agent #{@agent_id} started, #{@registry.size} workloads registered" }
      Log.info { "polling every #{@amqp.poll_interval.total_seconds}s" }

      while @running
        begin
          ensure_connected
          process_next_task
        rescue ex : Exception
          Log.error { "unexpected error in poll loop: #{ex.class}: #{ex.message}" }
          Log.debug { ex.backtrace.try(&.join("\n")) }
          sleep 5.seconds if @running
        end
      end

      Log.info { "agent #{@agent_id} shutting down" }
      @amqp.close
    end

    def stop : Nil
      @running = false
    end

    private def connect_with_retry : Nil
      loop do
        begin
          @amqp.connect
          return
        rescue ex : Exception
          Log.error { "AMQP connection failed: #{ex.message}, retrying in 5s..." }
          sleep 5.seconds
        end
      end
    end

    private def ensure_connected : Nil
      unless @amqp.connected?
        Log.info { "AMQP disconnected, reconnecting..." }
        @amqp.reconnect
      end
    end

    private def process_next_task : Nil
      processed = false

      @amqp.process_task do |task|
        processed = true
        Log.info { "received task: #{task.task_id} workload=#{task.workload} submitted_by=#{task.submitted_by}" }

        result = execute_task(task)
        Log.info { "task #{task.task_id} completed: exit_code=#{result.exit_code} duration=#{result.duration_us}us" }
        result
      end

      sleep @amqp.poll_interval unless processed
    end

    def execute_task(task : Task) : TaskResult
      workload = @registry.find(task.workload)

      unless workload
        Log.warn { "unknown workload: #{task.workload}" }
        return TaskResult.error(task.task_id, @agent_id, "unknown workload: #{task.workload}")
      end

      begin
        execution = @executor.run(workload, task.params)
        TaskResult.from_execution(task.task_id, @agent_id, execution)
      rescue ex : ValidationError
        Log.warn { "validation error for task #{task.task_id}: #{ex.message}" }
        TaskResult.error(task.task_id, @agent_id, ex.message || "validation error")
      rescue ex : Exception
        Log.error { "execution error for task #{task.task_id}: #{ex.class}: #{ex.message}" }
        TaskResult.error(task.task_id, @agent_id, "execution error: #{ex.message}")
      end
    end
  end
end
