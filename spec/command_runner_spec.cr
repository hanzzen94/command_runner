require "./spec_helper"

describe CommandRunner do
  it "has a version" do
    CommandRunner::VERSION.should eq("0.1.0")
  end
end
