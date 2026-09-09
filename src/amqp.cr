require "amqp-client"
require "openssl"
require "./tls"

module CommandRunner
  class AmqpClient
    @connection : AMQP::Client::Connection?
    @tls_context : OpenSSL::SSL::Context::Client?

    getter task_queue_prefix : String
    getter result_queue : String

    def initialize(config : AmqpConfig, @agent_id : String? = nil)
      @url = config.url
      @task_queue_prefix = config.task_queue
      @result_queue = config.result_queue
      @poll_interval = config.poll_interval.seconds

      if config.ca
        @tls_context = TLS.build_client_context(config.ca.not_nil!)
      end
    end

    def connect : Nil
      tls = @tls_context
      if tls
        @connection = AMQP::Client.new(@url, tls: tls).connect
      else
        @connection = AMQP::Client.new(@url).connect
      end

      @connection.not_nil!.on_disconnect do |ex|
        Log.warn { "AMQP connection lost: #{ex.message}" }
      end

      declare_queues
      Log.info { "AMQP connected" }
    end

    def connected? : Bool
      conn = @connection
      conn ? !conn.closed? : false
    end

    def reconnect : Nil
      close
      connect
    end

    def poll_interval : Time::Span
      @poll_interval
    end

    def task_queue_for(agent_id : String) : String
      "#{@task_queue_prefix}.#{agent_id}"
    end

    private def declare_queues : Nil
      conn = connection
      conn.channel do |ch|
        ch.queue(@result_queue, durable: true)
        if aid = @agent_id
          q = task_queue_for(aid)
          ch.queue(q, durable: true)
          Log.info { "declared task queue: #{q}" }
        end
      end
    end

    def publish_task(task : Task) : Bool
      ch = connection.channel
      begin
        q = task_queue_for(task.agent_id)
        ch.queue(q, durable: true)
        ch.basic_publish_confirm(task.to_json, exchange: "", routing_key: q,
          props: AMQP::Client::Properties.new(delivery_mode: 2_u8))
      ensure
        ch.close
      end
    end

    def publish_result(result : TaskResult) : Bool
      ch = connection.channel
      begin
        q = ch.queue(@result_queue, durable: true)
        q.publish_confirm(result.to_json, props: AMQP::Client::Properties.new(delivery_mode: 2_u8))
      ensure
        ch.close
      end
    end

    def process_task(&block : Task -> TaskResult?) : Nil
      aid = @agent_id
      raise Error.new("agent_id required for process_task") unless aid

      ch = connection.channel
      begin
        q = task_queue_for(aid)
        msg = ch.basic_get(q, no_ack: false)
        return unless msg

        task = Task.from_json(msg.body_io.to_s)
        result = block.call(task)

        if result
          rq = ch.queue(@result_queue, durable: true)
          rq.publish_confirm(result.to_json, props: AMQP::Client::Properties.new(delivery_mode: 2_u8))
        end

        ch.basic_ack(msg.delivery_tag)
      ensure
        ch.close
      end
    end

    def consume_results(&block : TaskResult -> Nil) : Nil
      conn = connection
      ch = conn.channel
      ch.prefetch(10)
      q = ch.queue(@result_queue, durable: true)

      q.subscribe(no_ack: false, block: true) do |msg|
        result = TaskResult.from_json(msg.body_io.to_s)
        block.call(result)
        msg.ack
      end
    end

    def close : Nil
      @connection.try do |conn|
        conn.close unless conn.closed?
      end
      @connection = nil
    end

    private def connection : AMQP::Client::Connection
      conn = @connection
      raise Error.new("AMQP not connected") unless conn && !conn.closed?
      conn
    end
  end
end
