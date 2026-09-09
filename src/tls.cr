require "openssl"

module CommandRunner
  module TLS
    def self.build_context(config : Config::TLSConfig) : OpenSSL::SSL::Context::Server
      context = OpenSSL::SSL::Context::Server.new

      unless File.exists?(config.cert)
        raise Error.new("Server certificate not found: #{config.cert}")
      end
      unless File.exists?(config.key)
        raise Error.new("Server private key not found: #{config.key}")
      end
      unless File.exists?(config.ca)
        raise Error.new("CA certificate not found: #{config.ca}")
      end

      context.certificate_chain = config.cert
      context.private_key = config.key
      context.ca_certificates = config.ca

      context.verify_mode =
        OpenSSL::SSL::VerifyMode::PEER | OpenSSL::SSL::VerifyMode::FAIL_IF_NO_PEER_CERT

      context.security_level = 2

      context
    end
  end
end
