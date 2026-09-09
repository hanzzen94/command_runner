require "http/server"
require "openssl/ssl/socket"

class HTTP::Server::Response
  def underlying_io : IO
    @io
  end

  def headers_written? : Bool
    @wrote_headers
  end
end

class HTTP::Server::Context
  property client_cn : String?
end

module CommandRunner
  class AuthHandler
    include HTTP::Handler

    def initialize(@allowed_clients : Set(String))
    end

    def call(context : HTTP::Server::Context) : Nil
      cn = extract_client_cn(context)
      context.client_cn = cn

      if cn.nil?
        respond_forbidden(context, "no client certificate")
        return
      end

      unless @allowed_clients.includes?(cn)
        respond_forbidden(context, "client not authorized")
        return
      end

      call_next(context)
    end

    private def extract_client_cn(context : HTTP::Server::Context) : String?
      io = context.response.underlying_io
      return nil unless io.is_a?(OpenSSL::SSL::Socket::Server)

      cert = io.peer_certificate
      return nil unless cert

      cert.subject.to_a.each do |oid, value|
        return value if oid == "CN"
      end

      nil
    end

    private def respond_forbidden(context : HTTP::Server::Context, message : String) : Nil
      Log.warn { "auth denied: #{message} (remote: #{context.request.remote_address})" }
      context.response.status_code = 403
      context.response.content_type = "application/json"
      context.response.print(%({"error":"forbidden"}))
    end
  end
end
