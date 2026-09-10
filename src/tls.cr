require "openssl"

module CommandRunner
  module TLS
    def self.build_context(config : TLSConfig) : OpenSSL::SSL::Context::Server
      context = OpenSSL::SSL::Context::Server.new

      validate_cert_files(config.cert, config.key, config.ca)

      context.certificate_chain = config.cert
      context.private_key = config.key
      context.ca_certificates = config.ca

      context.verify_mode =
        OpenSSL::SSL::VerifyMode::PEER | OpenSSL::SSL::VerifyMode::FAIL_IF_NO_PEER_CERT

      context.security_level = 2

      context
    end

    def self.build_client_context(ca_path : String, cert : String? = nil, key : String? = nil) : OpenSSL::SSL::Context::Client
      context = OpenSSL::SSL::Context::Client.new

      unless File.exists?(ca_path)
        raise Error.new("CA certificate not found: #{ca_path}")
      end

      context.ca_certificates = ca_path
      context.verify_mode = OpenSSL::SSL::VerifyMode::PEER
      context.security_level = 2

      if cert && key
        unless File.exists?(cert)
          raise Error.new("Client certificate not found: #{cert}")
        end
        unless File.exists?(key)
          raise Error.new("Client private key not found: #{key}")
        end
        context.certificate_chain = cert
        context.private_key = key
      end

      context
    end

    private def self.validate_cert_files(cert : String, key : String, ca : String) : Nil
      unless File.exists?(cert)
        raise Error.new("Server certificate not found: #{cert}")
      end
      unless File.exists?(key)
        raise Error.new("Server private key not found: #{key}")
      end
      unless File.exists?(ca)
        raise Error.new("CA certificate not found: #{ca}")
      end
    end
  end
end
