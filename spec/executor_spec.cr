require "./spec_helper"
include CommandRunner

# Platform-specific test commands
{% if flag?(:win32) %}
  ECHO       = ["cmd.exe", "/c", "echo"]
  SH         = ["cmd.exe", "/c"]
  SLEEP      = ["timeout.exe", "/t", "/nobreak"]
  TRUE       = ["cmd.exe", "/c", "exit", "0"]
  BIG_OUT    = ["powershell", "-NoProfile", "-Command", "'hello ' * 50000"]
  STDERR_CMD = SH + ["echo out& echo err 1>&2"]
{% else %}
  ECHO       = ["/bin/echo"]
  SH         = ["/bin/sh", "-c"]
  SLEEP      = ["/bin/sleep"]
  TRUE       = ["/bin/true"]
  BIG_OUT    = ["/bin/sh", "-c", "yes hello | head -c 100000"]
  STDERR_CMD = SH + ["echo out; echo err >&2"]
{% end %}

describe CommandRunner::Executor do
  executor = Executor.new(1_048_576)

  it "runs a simple command" do
    workload = Workload.from_config(
      Config::WorkloadConfig.from_yaml(<<-YAML),
      name: echo
      command: #{ECHO + ["hello world"]}
      YAML
      30
    )

    result = executor.run(workload, {} of String => String)
    result.exit_code.should eq(0)
    result.stdout.strip.should eq("hello world")
    result.stderr.should be_empty
    result.truncated.should be_false
    result.timed_out.should be_false
    result.duration_us.should be >= 0
  end

  it "captures nonzero exit codes" do
    workload = Workload.from_config(
      Config::WorkloadConfig.from_yaml(<<-YAML),
      name: fail
      command: #{SH + ["exit 7"]}
      YAML
      30
    )

    result = executor.run(workload, {} of String => String)
    result.exit_code.should eq(7)
  end

  it "captures stderr separately" do
    workload = Workload.from_config(
      Config::WorkloadConfig.from_yaml(<<-YAML),
      name: stderr_test
      command: #{STDERR_CMD}
      YAML
      30
    )

    result = executor.run(workload, {} of String => String)
    result.stdout.strip.should eq("out")
    result.stderr.strip.should eq("err")
  end

  it "substitutes params" do
    workload = Workload.from_config(
      Config::WorkloadConfig.from_yaml(<<-YAML),
      name: echo_param
      command: #{ECHO + ["{msg}"]}
      params:
        - name: msg
          required: true
      YAML
      30
    )

    result = executor.run(workload, {"msg" => "test123"})
    result.stdout.strip.should eq("test123")
  end

  it "kills on timeout" do
    workload = Workload.from_config(
      Config::WorkloadConfig.from_yaml(<<-YAML),
      name: slow
      command: #{SLEEP + ["30"]}
      timeout: 1
      YAML
      30
    )

    result = executor.run(workload, {} of String => String)
    result.timed_out.should be_true
    result.duration_us.should be < 5000000
  end

  it "truncates large output" do
    workload = Workload.from_config(
      Config::WorkloadConfig.from_yaml(<<-YAML),
      name: verbose
      command: #{BIG_OUT}
      YAML
      30
    )

    small_executor = Executor.new(100)
    result = small_executor.run(workload, {} of String => String)
    result.truncated.should be_true
    result.stdout.bytesize.should eq(100)
  end

  it "raises on missing required param" do
    workload = Workload.from_config(
      Config::WorkloadConfig.from_yaml(<<-YAML),
      name: needs_param
      command: #{ECHO + ["{val}"]}
      params:
        - name: val
          required: true
      YAML
      30
    )

    expect_raises(ValidationError) do
      executor.run(workload, {} of String => String)
    end
  end

  it "raises on unknown param" do
    workload = Workload.from_config(
      Config::WorkloadConfig.from_yaml(<<-YAML),
      name: no_params
      command: #{TRUE}
      YAML
      30
    )

    expect_raises(ValidationError) do
      executor.run(workload, {"bogus" => "x"})
    end
  end
end
