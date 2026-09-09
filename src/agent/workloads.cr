module CommandRunner
  struct ParamSpec
    getter name : String
    getter required : Bool
    getter pattern : Regex?

    def initialize(@name : String, @required : Bool, @pattern : Regex?)
    end

    def validate(value : String) : Bool
      if pat = @pattern
        value.matches?(pat)
      else
        true
      end
    end
  end

  struct Workload
    getter name : String
    getter command : Array(String)
    getter params : Array(ParamSpec)
    getter allowed_clients : Set(String)
    getter timeout : Int32
    getter cwd : String?

    def initialize(
      @name : String,
      @command : Array(String),
      @params : Array(ParamSpec),
      @allowed_clients : Set(String),
      @timeout : Int32,
      @cwd : String?,
    )
    end

    def self.from_config(wc : WorkloadConfig, default_timeout : Int32) : self
      params = wc.params.map do |pc|
        pattern = pc.pattern.try { |p| Regex.new(p) }
        ParamSpec.new(pc.name, pc.required, pattern)
      end

      timeout = wc.timeout || default_timeout

      new(
        name: wc.name,
        command: wc.command,
        params: params,
        allowed_clients: wc.allowed_clients.to_set,
        timeout: timeout,
        cwd: wc.cwd,
      )
    end

    def param_names : Set(String)
      @params.map(&.name).to_set
    end

    def allowed?(client_cn : String) : Bool
      @allowed_clients.empty? || @allowed_clients.includes?(client_cn)
    end

    def build_command(params : Hash(String, String)) : Array(String)
      known = param_names
      resolved = [] of String

      @command.each do |part|
        resolved << part.gsub(/\{(\w+)\}/) do |_, match|
          param_name = match[1]
          raise ValidationError.new("unknown parameter: #{param_name}") unless known.includes?(param_name)
          value = params[param_name]?
          raise ValidationError.new("missing required parameter: #{param_name}") unless value
          value
        end
      end

      resolved
    end

    def validate_params(params : Hash(String, String)) : Nil
      known = param_names

      params.each_key do |key|
        unless known.includes?(key)
          raise ValidationError.new("unknown parameter: #{key}")
        end
      end

      @params.each do |spec|
        value = params[spec.name]?
        if value.nil?
          raise ValidationError.new("missing required parameter: #{spec.name}") if spec.required
        elsif !spec.validate(value)
          raise ValidationError.new("parameter #{spec.name} failed validation")
        end
      end
    end
  end

  class WorkloadRegistry
    private getter workloads : Hash(String, Workload)

    def initialize(configs : Array(WorkloadConfig), default_timeout : Int32)
      @workloads = {} of String => Workload
      configs.each do |wc|
        if @workloads.has_key?(wc.name)
          raise Error.new("Duplicate workload name: #{wc.name}")
        end
        @workloads[wc.name] = Workload.from_config(wc, default_timeout)
      end
    end

    def find(name : String) : Workload?
      @workloads[name]?
    end

    def all : Array(Workload)
      @workloads.values
    end

    def visible_to(client_cn : String) : Array(Workload)
      @workloads.values.select { |w| w.allowed?(client_cn) }
    end

    def size : Int32
      @workloads.size
    end
  end
end
