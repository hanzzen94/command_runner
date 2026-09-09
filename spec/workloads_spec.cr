require "./spec_helper"
include CommandRunner

describe CommandRunner::Workload do
  describe ".from_config" do
    it "compiles param patterns into regexes" do
      wc = Config::WorkloadConfig.from_yaml(<<-YAML)
      name: test
      command: ["/bin/echo", "{val}"]
      params:
        - name: val
          required: true
          pattern: "^[a-z]+$"
      YAML

      w = Workload.from_config(wc, 30)
      w.name.should eq("test")
      w.timeout.should eq(30)
      w.params.size.should eq(1)
      w.params[0].required.should be_true
      w.params[0].validate("abc").should be_true
      w.params[0].validate("abc123").should be_false
    end

    it "uses default timeout when not specified" do
      wc = Config::WorkloadConfig.from_yaml(<<-YAML)
      name: test
      command: ["/bin/true"]
      YAML

      w = Workload.from_config(wc, 42)
      w.timeout.should eq(42)
    end

    it "uses workload timeout over default" do
      wc = Config::WorkloadConfig.from_yaml(<<-YAML)
      name: test
      command: ["/bin/true"]
      timeout: 10
      YAML

      w = Workload.from_config(wc, 42)
      w.timeout.should eq(10)
    end
  end

  describe "#allowed?" do
    it "allows any client when no restriction" do
      wc = Config::WorkloadConfig.from_yaml(<<-YAML)
      name: open
      command: ["/bin/true"]
      YAML

      w = Workload.from_config(wc, 30)
      w.allowed?("anyone").should be_true
    end

    it "restricts to listed clients" do
      wc = Config::WorkloadConfig.from_yaml(<<-YAML)
      name: restricted
      command: ["/bin/true"]
      allowed_clients:
        - alice
        - bob
      YAML

      w = Workload.from_config(wc, 30)
      w.allowed?("alice").should be_true
      w.allowed?("bob").should be_true
      w.allowed?("eve").should be_false
    end
  end

  describe "#build_command" do
    it "substitutes {param} placeholders" do
      wc = Config::WorkloadConfig.from_yaml(<<-YAML)
      name: echo
      command: ["/bin/echo", "{msg}"]
      params:
        - name: msg
          required: true
      YAML

      w = Workload.from_config(wc, 30)
      cmd = w.build_command({"msg" => "hello"})
      cmd.should eq(["/bin/echo", "hello"])
    end

    it "substitutes inline {param} within a larger argument" do
      wc = Config::WorkloadConfig.from_yaml(<<-YAML)
      name: chef
      command: ["sudo", "chef-client", "-o", "recipe[{recipe}]"]
      params:
        - name: recipe
          required: true
          pattern: "^[a-zA-Z0-9_:-]+$"
      YAML

      w = Workload.from_config(wc, 30)
      cmd = w.build_command({"recipe" => "cookbook::default"})
      cmd.should eq(["sudo", "chef-client", "-o", "recipe[cookbook::default]"])
    end

    it "raises on missing required param" do
      wc = Config::WorkloadConfig.from_yaml(<<-YAML)
      name: echo
      command: ["/bin/echo", "{msg}"]
      params:
        - name: msg
          required: true
      YAML

      w = Workload.from_config(wc, 30)
      expect_raises(ValidationError, "missing required parameter: msg") do
        w.build_command({} of String => String)
      end
    end

    it "passes through non-placeholder args" do
      wc = Config::WorkloadConfig.from_yaml(<<-YAML)
      name: df
      command: ["/bin/df", "-h"]
      YAML

      w = Workload.from_config(wc, 30)
      cmd = w.build_command({} of String => String)
      cmd.should eq(["/bin/df", "-h"])
    end
  end

  describe "#validate_params" do
    it "rejects unknown params" do
      wc = Config::WorkloadConfig.from_yaml(<<-YAML)
      name: test
      command: ["/bin/true"]
      YAML

      w = Workload.from_config(wc, 30)
      expect_raises(ValidationError, "unknown parameter: bogus") do
        w.validate_params({"bogus" => "x"})
      end
    end

    it "rejects missing required params" do
      wc = Config::WorkloadConfig.from_yaml(<<-YAML)
      name: test
      command: ["/bin/echo", "{val}"]
      params:
        - name: val
          required: true
      YAML

      w = Workload.from_config(wc, 30)
      expect_raises(ValidationError, "missing required parameter: val") do
        w.validate_params({} of String => String)
      end
    end

    it "rejects params that fail pattern" do
      wc = Config::WorkloadConfig.from_yaml(<<-YAML)
      name: test
      command: ["/bin/echo", "{val}"]
      params:
        - name: val
          required: true
          pattern: "^[a-z]+$"
      YAML

      w = Workload.from_config(wc, 30)
      expect_raises(ValidationError, "parameter val failed validation") do
        w.validate_params({"val" => "ABC123"})
      end
    end

    it "passes with valid params" do
      wc = Config::WorkloadConfig.from_yaml(<<-YAML)
      name: test
      command: ["/bin/echo", "{val}"]
      params:
        - name: val
          required: true
          pattern: "^[a-z]+$"
      YAML

      w = Workload.from_config(wc, 30)
      w.validate_params({"val" => "abc"})
    end
  end
end

describe CommandRunner::WorkloadRegistry do
  it "builds registry from config" do
    configs = [
      Config::WorkloadConfig.from_yaml(<<-YAML),
      name: alpha
      command: ["/bin/true"]
      YAML
      Config::WorkloadConfig.from_yaml(<<-YAML),
      name: beta
      command: ["/bin/true"]
      allowed_clients:
        - alice
      YAML
    ]

    registry = WorkloadRegistry.new(configs, 30)
    registry.size.should eq(2)
    registry.find("alpha").should_not be_nil
    registry.find("beta").should_not be_nil
    registry.find("gamma").should be_nil
  end

  it "raises on duplicate names" do
    configs = [
      Config::WorkloadConfig.from_yaml(<<-YAML),
      name: dup
      command: ["/bin/true"]
      YAML
      Config::WorkloadConfig.from_yaml(<<-YAML),
      name: dup
      command: ["/bin/true"]
      YAML
    ]

    expect_raises(CommandRunner::Error, "Duplicate workload name: dup") do
      WorkloadRegistry.new(configs, 30)
    end
  end

  it "filters visible workloads by client" do
    configs = [
      Config::WorkloadConfig.from_yaml(<<-YAML),
      name: open
      command: ["/bin/true"]
      YAML
      Config::WorkloadConfig.from_yaml(<<-YAML),
      name: restricted
      command: ["/bin/true"]
      allowed_clients:
        - alice
      YAML
    ]

    registry = WorkloadRegistry.new(configs, 30)
    registry.visible_to("alice").map(&.name).should contain("open")
    registry.visible_to("alice").map(&.name).should contain("restricted")
    registry.visible_to("bob").map(&.name).should contain("open")
    registry.visible_to("bob").map(&.name).should_not contain("restricted")
  end
end
