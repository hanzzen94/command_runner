module CommandRunner
  VERSION = "0.1.0"
  Log     = ::Log.for("command_runner")

  class Error < Exception; end

  class ValidationError < Error; end

  class WorkloadNotFound < Error; end
end

require "log"
