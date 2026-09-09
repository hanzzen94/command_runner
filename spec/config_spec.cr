require "./spec_helper"
include CommandRunner

describe CommandRunner::AgentConfig do
  it "parses a full agent config" do
    yaml = <<-YAML
    agent_id: "server-01"
    amqp:
      url: "amqp://agent:pass@localhost:5672"
      task_queue: "tasks"
      result_queue: "results"
      poll_interval: 3
    limits:
      output_bytes: 2048
      default_timeout: 15
    workloads:
      - name: echo
        command: ["/bin/echo", "{msg}"]
        params:
          - name: msg
            required: true
            pattern: "^[a-z]+$"
        timeout: 5
        cwd: /tmp
      - name: status
        command: ["/bin/true"]
    YAML

    config = AgentConfig.from_yaml(yaml)
    config.agent_id.should eq("server-01")
    config.amqp.url.should eq("amqp://agent:pass@localhost:5672")
    config.amqp.task_queue.should eq("tasks")
    config.amqp.result_queue.should eq("results")
    config.amqp.poll_interval.should eq(3)
    config.limits.output_bytes.should eq(2048)
    config.limits.default_timeout.should eq(15)

    config.workloads.size.should eq(2)
    w0 = config.workloads[0]
    w0.name.should eq("echo")
    w0.command.should eq(["/bin/echo", "{msg}"])
    w0.params.size.should eq(1)
    w0.params[0].name.should eq("msg")
    w0.params[0].required.should be_true
    w0.params[0].pattern.should eq("^[a-z]+$")
    w0.timeout.should eq(5)
    w0.cwd.should eq("/tmp")

    w1 = config.workloads[1]
    w1.name.should eq("status")
    w1.params.should be_empty
    w1.timeout.should be_nil
    w1.cwd.should be_nil
  end

  it "applies defaults for missing fields" do
    yaml = <<-YAML
    agent_id: "node-1"
    amqp:
      url: "amqp://localhost"
    workloads:
      - name: hello
        command: ["/bin/true"]
    YAML

    config = AgentConfig.from_yaml(yaml)
    config.amqp.task_queue.should eq("tasks")
    config.amqp.result_queue.should eq("results")
    config.amqp.poll_interval.should eq(5)
    config.limits.output_bytes.should eq(1_048_576)
    config.limits.default_timeout.should eq(30)
    config.workloads[0].params.should be_empty
    config.workloads[0].allowed_clients.should be_empty
  end
end

describe CommandRunner::ServerConfig do
  it "parses a full server config" do
    yaml = <<-YAML
    listen: "0.0.0.0:9000"
    tls:
      cert: /path/cert.pem
      key: /path/key.pem
      ca: /path/ca.pem
    amqp:
      url: "amqp://server:pass@localhost:5672"
    allowed_clients:
      - alice
      - bob
    limits:
      request_body_bytes: 1024
      rate_per_minute: 30
    results:
      url: "postgres://user:pass@localhost:5432/db"
      results_limit: 50
    YAML

    config = ServerConfig.from_yaml(yaml)
    config.listen.should eq("0.0.0.0:9000")
    config.tls.cert.should eq("/path/cert.pem")
    config.amqp.url.should eq("amqp://server:pass@localhost:5672")
    config.allowed_clients.should eq(["alice", "bob"])
    config.limits.request_body_bytes.should eq(1024)
    config.limits.rate_per_minute.should eq(30)
    config.results.url.should eq("postgres://user:pass@localhost:5432/db")
    config.results.results_limit.should eq(50)
  end

  it "applies defaults for missing fields" do
    yaml = <<-YAML
    tls:
      cert: c
      key: k
      ca: a
    amqp:
      url: "amqp://localhost"
    YAML

    config = ServerConfig.from_yaml(yaml)
    config.listen.should eq("0.0.0.0:8443")
    config.allowed_clients.should be_empty
    config.limits.request_body_bytes.should eq(65536)
    config.limits.rate_per_minute.should eq(60)
    config.results.results_limit.should eq(100)
    config.amqp.task_queue.should eq("tasks")
    config.amqp.result_queue.should eq("results")
  end
end
