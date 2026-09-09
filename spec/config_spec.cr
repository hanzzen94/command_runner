require "./spec_helper"
include CommandRunner

describe CommandRunner::Config do
  it "parses a full config" do
    yaml = <<-YAML
    listen: "0.0.0.0:9000"
    tls:
      cert: /path/cert.pem
      key: /path/key.pem
      ca: /path/ca.pem
    allowed_clients:
      - alice
      - bob
    limits:
      request_body_bytes: 1024
      output_bytes: 2048
      default_timeout: 15
      rate_per_minute: 30
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

    config = Config.from_yaml(yaml)
    config.listen.should eq("0.0.0.0:9000")
    config.tls.cert.should eq("/path/cert.pem")
    config.allowed_clients.should eq(["alice", "bob"])
    config.limits.request_body_bytes.should eq(1024)
    config.limits.output_bytes.should eq(2048)
    config.limits.default_timeout.should eq(15)
    config.limits.rate_per_minute.should eq(30)

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
    tls:
      cert: c
      key: k
      ca: a
    workloads:
      - name: hello
        command: ["/bin/true"]
    YAML

    config = Config.from_yaml(yaml)
    config.listen.should eq("127.0.0.1:8443")
    config.allowed_clients.should be_empty
    config.limits.request_body_bytes.should eq(65536)
    config.limits.default_timeout.should eq(30)
    config.workloads[0].params.should be_empty
    config.workloads[0].allowed_clients.should be_empty
  end
end
