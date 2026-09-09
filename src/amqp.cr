require "amqp-client"
require "openssl"
require "./tls"

module CommandRunner
  class AmqpClient
    @connection : AMQP::Client::Connection?
    @tls_context : OpenSSL::SSL::Context::Client?

    getter task_queue : String
    getter result_queue : String

    def initialize(config : AmqpConfig)
      @url = config.url
      @task_queue = config.task_queue
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

    private def declare_queues : Nil
      conn = connection
      conn.channel do |ch|
        ch.queue(@task_queue, durable: true)
        ch.queue(@result_queue, durable: true)
      end
    end

    def publish_task(task : Task) : Bool
      ch = connection.channel
      begin
        q = ch.queue(@task_queue, durable: true)
        q.publish_confirm(task.to_json, props: AMQP::Client::Properties.new(delivery_mode: 2_u8))
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
      ch = connection.channel
      begin
        msg = ch.basic_get(@task_queue, no_ack: false)
        return unless msg

        task = Task.from_json(msg.body_io.to_s)
        result = block.call(task)

        if result
          q = ch.queue(@result_queue, durable: true)
          q.publish_confirm(result.to_json, props: AMQP::Client::Properties.new(delivery_mode: 2_u8))
        end

        ch.basic_ack(msg.delivery_tag)
      ensure
        ch.close
      end
    end

    def nack_task(delivery_tag : UInt64, requeue : Bool = false) : Nil
      ch = connection.channel
      begin
        ch.basic_nack(delivery_tag, requeue: requeue)
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
