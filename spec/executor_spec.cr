require "./spec_helper"
include CommandRunner

describe CommandRunner::Executor do
  executor = Executor.new(1_048_576)

  it "runs a simple command" do
    workload = Workload.from_config(
      Config::WorkloadConfig.from_yaml(<<-YAML),
      name: echo
      command: ["/bin/echo", "hello world"]
      YAML
      30
    )

    result = executor.run(workload, {} of String => String)
    result.exit_code.should eq(0)
    result.stdout.strip.should eq("hello world")
    result.stderr.should be_empty
    result.truncated.should be_false
    result.timed_out.should be_false
    result.duration_ms.should be >= 0
  end

  it "captures nonzero exit codes" do
    workload = Workload.from_config(
      Config::WorkloadConfig.from_yaml(<<-YAML),
      name: fail
      command: ["/bin/sh", "-c", "exit 7"]
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
      command: ["/bin/sh", "-c", "echo out; echo err >&2"]
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
      command: ["/bin/echo", "{msg}"]
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
      command: ["/bin/sleep", "30"]
      timeout: 1
      YAML
      30
    )

    result = executor.run(workload, {} of String => String)
    result.timed_out.should be_true
    result.exit_code.should eq(-1)
    result.duration_ms.should be < 5000
  end

  it "truncates large output" do
    workload = Workload.from_config(
      Config::WorkloadConfig.from_yaml(<<-YAML),
      name: verbose
      command: ["/bin/sh", "-c", "yes hello | head -c 100000"]
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
      command: ["/bin/echo", "{val}"]
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
      command: ["/bin/true"]
      YAML
      30
    )

    expect_raises(ValidationError) do
      executor.run(workload, {"bogus" => "x"})
    end
  end
end
