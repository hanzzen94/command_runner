require "./spec_helper"
include CommandRunner

describe CommandRunner::TLS do
  it "builds a context with forced peer verification" do
    dir = File.join(Dir.tempdir, "cr_tls_test_#{Random.rand(100000)}")
    Dir.mkdir(dir)

    begin
      system("openssl genrsa -out #{dir}/ca.key 2048 2>/dev/null")
      system("openssl req -x509 -new -nodes -key #{dir}/ca.key -sha256 -days 1 -subj /CN=test-ca -out #{dir}/ca.crt")
      system("openssl genrsa -out #{dir}/server.key 2048 2>/dev/null")
      system("openssl req -new -key #{dir}/server.key -subj /CN=localhost -out #{dir}/server.csr")
      system("openssl x509 -req -in #{dir}/server.csr -CA #{dir}/ca.crt -CAkey #{dir}/ca.key -CAcreateserial -out #{dir}/server.crt -days 1 -sha256 2>/dev/null")

      config = Config::TLSConfig.from_yaml({"cert" => "#{dir}/server.crt", "key" => "#{dir}/server.key", "ca" => "#{dir}/ca.crt"}.to_yaml)
      context = TLS.build_context(config)

      context.verify_mode.includes?(OpenSSL::SSL::VerifyMode::PEER).should be_true
      context.verify_mode.includes?(OpenSSL::SSL::VerifyMode::FAIL_IF_NO_PEER_CERT).should be_true
      context.security_level.should eq(2)
    ensure
      `rm -rf #{dir}`
    end
  end

  it "raises when cert files are missing" do
    config = Config::TLSConfig.from_yaml({"cert" => "/nonexistent/cert", "key" => "/nonexistent/key", "ca" => "/nonexistent/ca"}.to_yaml)

    expect_raises(CommandRunner::Error, "Server certificate not found") do
      TLS.build_context(config)
    end
  end
end
