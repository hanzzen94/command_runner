require "yaml"

module CommandRunner
  struct AmqpConfig
    include YAML::Serializable

    getter url : String
    getter task_queue : String = "tasks"
    getter result_queue : String = "results"
    getter poll_interval : Int32 = 5
    getter ca : String? = nil
    getter cert : String? = nil
    getter key : String? = nil

    def self.load(path : String) : self
      from_yaml(File.read(path))
    end
  end

  struct Limits
    include YAML::Serializable

    getter request_body_bytes : Int32 = 65536
    getter output_bytes : Int32 = 1_048_576
    getter default_timeout : Int32 = 30
    getter rate_per_minute : Int32 = 60

    def initialize
    end
  end

  struct TLSConfig
    include YAML::Serializable

    getter cert : String
    getter key : String
    getter ca : String
  end

  struct DatabaseConfig
    include YAML::Serializable

    getter url : String
    getter results_limit : Int32 = 100

    def initialize(@url : String = "", @results_limit : Int32 = 100)
    end
  end

  struct WorkloadConfig
    include YAML::Serializable

    getter name : String
    getter command : Array(String)
    getter params : Array(ParamConfig) = [] of ParamConfig
    getter allowed_clients : Array(String) = [] of String
    getter timeout : Int32?
    getter cwd : String?

    struct ParamConfig
      include YAML::Serializable

      getter name : String
      getter? required : Bool = false
      getter pattern : String?
    end
  end

  struct AgentConfig
    include YAML::Serializable

    getter server_cloud_id : String
    getter amqp : AmqpConfig
    getter limits : Limits = Limits.new
    getter workloads : Array(WorkloadConfig)

    def self.load(path : String) : self
      from_yaml(File.read(path))
    end
  end

  struct ServerConfig
    include YAML::Serializable

    getter listen : String = "0.0.0.0:8443"
    getter tls : TLSConfig
    getter amqp : AmqpConfig
    getter allowed_clients : Array(String) = [] of String
    getter limits : Limits = Limits.new
    getter results : DatabaseConfig = DatabaseConfig.new

    def self.load(path : String) : self
      from_yaml(File.read(path))
    end
  end
end
