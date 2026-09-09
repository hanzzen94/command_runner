require "process"
require "json"

module CommandRunner
  struct ExecutionResult
    include JSON::Serializable

    getter exit_code : Int32
    getter stdout : String
    getter stderr : String
    getter truncated : Bool
    getter timed_out : Bool
    getter duration_us : Int64

    def initialize(@exit_code, @stdout, @stderr, @truncated, @timed_out, @duration_us)
    end
  end

  class Executor
    def initialize(@output_limit : Int32)
    end

    def run(workload : Workload, params : Hash(String, String)) : ExecutionResult
      workload.validate_params(params)
      command = workload.build_command(params)

      start = Time.instant
      stdout_buf = IO::Memory.new
      stderr_buf = IO::Memory.new

      process = Process.new(
        command,
        output: Process::Redirect::Pipe,
        error: Process::Redirect::Pipe,
        chdir: workload.cwd,
      )

      stdout_done = Channel(Bool).new
      stderr_done = Channel(Bool).new

      spawn { stdout_done.send(read_capped(process.output, stdout_buf, @output_limit)) }
      spawn { stderr_done.send(read_capped(process.error, stderr_buf, @output_limit)) }

      wait_channel = Channel(Process::Status).new
      spawn { wait_channel.send(process.wait) }

      timed_out = false

      status = select
      when s = wait_channel.receive
        s
      when timeout(workload.timeout.seconds)
        begin
          process.terminate(graceful: true)
        rescue
        end
        timed_out = true
        wait_channel.receive
      end

      stdout_truncated = stdout_done.receive
      stderr_truncated = stderr_done.receive

      duration = (Time.instant - start).total_microseconds.to_i64

      ExecutionResult.new(
        exit_code: status.exit_code? || -1,
        stdout: stdout_buf.to_s,
        stderr: stderr_buf.to_s,
        truncated: stdout_truncated || stderr_truncated,
        timed_out: timed_out,
        duration_us: duration,
      )
    end

    private def read_capped(io : IO, buffer : IO::Memory, limit : Int32) : Bool
      truncated = false
      buf = Bytes.new(8192)
      limit_i64 = limit.to_i64

      while (len = io.read(buf)) > 0
        remaining = limit_i64 - buffer.pos
        if remaining > 0
          to_write = Math.min(len.to_i64, remaining).to_i32
          buffer.write(buf[0, to_write])
        end
        truncated = true if buffer.pos >= limit_i64
      end

      truncated
    end
  end
end
