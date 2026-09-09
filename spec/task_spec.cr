require "./spec_helper"
require "../src/agent/executor"
include CommandRunner

describe CommandRunner::Task do
  it "serializes and deserializes round-trip" do
    task = Task.new("echo", {"msg" => "hello"}, "ci-bot")
    json = task.to_json

    restored = Task.from_json(json)
    restored.task_id.should eq(task.task_id)
    restored.workload.should eq("echo")
    restored.params.should eq({"msg" => "hello"})
    restored.submitted_by.should eq("ci-bot")
    restored.submitted_at.should eq(task.submitted_at)
  end

  it "generates a unique task_id" do
    t1 = Task.new("echo", {} of String => String)
    t2 = Task.new("echo", {} of String => String)
    t1.task_id.should_not eq(t2.task_id)
  end

  it "defaults params to empty hash" do
    task = Task.new("disk_usage")
    task.params.should be_empty
    task.submitted_by.should eq("")
  end
end

describe CommandRunner::TaskResult do
  it "serializes and deserializes round-trip" do
    result = TaskResult.new(
      task_id: "abc-123",
      agent_id: "server-01",
      exit_code: 0,
      stdout: "hello\n",
      stderr: "",
      truncated: false,
      timed_out: false,
      duration_us: 5000_i64,
    )
    json = result.to_json

    restored = TaskResult.from_json(json)
    restored.task_id.should eq("abc-123")
    restored.agent_id.should eq("server-01")
    restored.exit_code.should eq(0)
    restored.stdout.should eq("hello\n")
    restored.stderr.should eq("")
    restored.truncated.should be_false
    restored.timed_out.should be_false
    restored.duration_us.should eq(5000)
    restored.error.should be_nil
  end

  it "builds from ExecutionResult" do
    execution = ExecutionResult.new(
      exit_code: 0,
      stdout: "ok",
      stderr: "",
      truncated: false,
      timed_out: false,
      duration_us: 100_i64,
    )
    result = TaskResult.from_execution("task-1", "agent-1", execution)
    result.task_id.should eq("task-1")
    result.agent_id.should eq("agent-1")
    result.exit_code.should eq(0)
    result.stdout.should eq("ok")
    result.error.should be_nil
  end

  it "builds error result" do
    result = TaskResult.error("task-1", "agent-1", "something went wrong")
    result.task_id.should eq("task-1")
    result.agent_id.should eq("agent-1")
    result.exit_code.should eq(-1)
    result.stdout.should eq("")
    result.error.should eq("something went wrong")
  end
end

describe CommandRunner::TaskReceipt do
  it "serializes to JSON" do
    receipt = TaskReceipt.new("abc-123", "queued")
    json = receipt.to_json
    restored = TaskReceipt.from_json(json)
    restored.task_id.should eq("abc-123")
    restored.status.should eq("queued")
  end
end
