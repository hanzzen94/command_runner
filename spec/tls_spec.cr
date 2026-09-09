require "./spec_helper"
include CommandRunner

describe CommandRunner::TLS do
  it "builds a context with forced peer verification" do
    dir = File.join(Dir.tempdir, "cr_tls_test_#{Random.rand(100000)}")
    Dir.mkdir(dir)

    begin
      run_openssl(dir, "genrsa", "-out", "ca.key", "2048")
      run_openssl(dir, "req", "-x509", "-new", "-nodes", "-key", "ca.key", "-sha256", "-days", "1", "-subj", "/CN=test-ca", "-out", "ca.crt")
      run_openssl(dir, "genrsa", "-out", "server.key", "2048")
      run_openssl(dir, "req", "-new", "-key", "server.key", "-subj", "/CN=localhost", "-out", "server.csr")
      run_openssl(dir, "x509", "-req", "-in", "server.csr", "-CA", "ca.crt", "-CAkey", "ca.key", "-CAcreateserial", "-out", "server.crt", "-days", "1", "-sha256")

      config = Config::TLSConfig.from_yaml({"cert" => "#{dir}/server.crt", "key" => "#{dir}/server.key", "ca" => "#{dir}/ca.crt"}.to_yaml)
      context = TLS.build_context(config)

      context.verify_mode.includes?(OpenSSL::SSL::VerifyMode::PEER).should be_true
      context.verify_mode.includes?(OpenSSL::SSL::VerifyMode::FAIL_IF_NO_PEER_CERT).should be_true
      context.security_level.should eq(2)
    ensure
      recursive_delete(dir)
    end
  end

  it "raises when cert files are missing" do
    config = Config::TLSConfig.from_yaml({"cert" => "/nonexistent/cert", "key" => "/nonexistent/key", "ca" => "/nonexistent/ca"}.to_yaml)

    expect_raises(CommandRunner::Error, "Server certificate not found") do
      TLS.build_context(config)
    end
  end
end

private def run_openssl(dir : String, *args : String) : Nil
  Process.new("openssl", args.to_a, output: Process::Redirect::Close, error: Process::Redirect::Close, chdir: dir).wait
end

private def recursive_delete(path : String) : Nil
  return unless Dir.exists?(path)
  Dir.each_child(path) do |entry|
    full = File.join(path, entry)
    if Dir.exists?(full) && !File.symlink?(full)
      recursive_delete(full)
    else
      File.delete(full)
    end
  end
  Dir.delete(path)
end
