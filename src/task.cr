require "json"
require "uuid"

module CommandRunner
  struct Task
    include JSON::Serializable

    getter task_id : String = UUID.v4.to_s
    getter workload : String
    getter params : Hash(String, String) = {} of String => String
    getter submitted_at : String = Time.utc.to_rfc3339
    getter submitted_by : String = ""

    def initialize(@workload : String, @params : Hash(String, String) = {} of String => String, @submitted_by : String = "")
    end
  end

  struct TaskResult
    include JSON::Serializable

    getter task_id : String
    getter agent_id : String
    getter exit_code : Int32
    getter stdout : String
    getter stderr : String
    getter truncated : Bool
    getter timed_out : Bool
    getter duration_us : Int64
    getter executed_at : String
    getter error : String?

    def initialize(
      @task_id : String,
      @agent_id : String,
      @exit_code : Int32,
      @stdout : String,
      @stderr : String,
      @truncated : Bool,
      @timed_out : Bool,
      @duration_us : Int64,
      @error : String? = nil,
      @executed_at : String = Time.utc.to_rfc3339,
    )
    end

    def self.from_execution(task_id : String, agent_id : String, result : ExecutionResult) : self
      new(
        task_id: task_id,
        agent_id: agent_id,
        exit_code: result.exit_code,
        stdout: result.stdout,
        stderr: result.stderr,
        truncated: result.truncated,
        timed_out: result.timed_out,
        duration_us: result.duration_us,
      )
    end

    def self.error(task_id : String, agent_id : String, message : String) : self
      new(
        task_id: task_id,
        agent_id: agent_id,
        exit_code: -1,
        stdout: "",
        stderr: "",
        truncated: false,
        timed_out: false,
        duration_us: 0,
        error: message,
      )
    end
  end

  struct TaskReceipt
    include JSON::Serializable

    getter task_id : String
    getter status : String

    def initialize(@task_id : String, @status : String)
    end
  end
end
