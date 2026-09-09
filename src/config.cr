require "yaml"

module CommandRunner
  struct Config
    include YAML::Serializable

    getter listen : String = "127.0.0.1:8443"
    getter tls : TLSConfig
    getter allowed_clients : Array(String) = [] of String
    getter limits : Limits = Limits.new
    getter workloads : Array(WorkloadConfig)

    def self.load(path : String) : self
      from_yaml(File.read(path))
    end

    struct TLSConfig
      include YAML::Serializable

      getter cert : String
      getter key : String
      getter ca : String
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
        getter required : Bool = false
        getter pattern : String?
      end
    end
  end
end
