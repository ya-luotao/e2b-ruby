# frozen_string_literal: true

require "spec_helper"

RSpec.describe E2B::E2BError do
  it "carries an optional status code and headers" do
    error = described_class.new("boom", status_code: 500, headers: { "x" => "y" })
    expect(error.message).to eq("boom")
    expect(error.status_code).to eq(500)
    expect(error.headers).to eq("x" => "y")
  end

  it "defaults headers to an empty hash even when passed nil" do
    expect(described_class.new("boom", headers: nil).headers).to eq({})
  end

  it "aliases SandboxError to E2BError" do
    expect(E2B::SandboxError).to be(described_class)
  end

  describe "the error hierarchy" do
    it "roots HTTP and domain errors at E2BError" do
      [E2B::NotFoundError, E2B::RateLimitError, E2B::AuthenticationError,
       E2B::ConfigurationError, E2B::ConflictError, E2B::TimeoutError,
       E2B::InvalidArgumentError, E2B::SandboxStateError].each do |klass|
        expect(klass.ancestors).to include(described_class)
      end
    end

    it "nests git and build error subclasses correctly" do
      expect(E2B::GitAuthError.ancestors).to include(E2B::AuthenticationError)
      expect(E2B::FileUploadError.ancestors).to include(E2B::BuildError)
    end
  end

  describe E2B::CommandExitError do
    it "builds a message from exit code, error and stderr" do
      error = described_class.new(stdout: "out", stderr: "bad", exit_code: 2, error: "failure")
      expect(error.exit_code).to eq(2)
      expect(error.stdout).to eq("out")
      expect(error.stderr).to eq("bad")
      expect(error.command_error).to eq("failure")
      expect(error.message).to include("Command exited with code 2")
      expect(error.message).to include("failure")
      expect(error.message).to include("Stderr: bad")
    end

    it "omits the stderr line when stderr is empty" do
      expect(described_class.new(exit_code: 1).message).not_to include("Stderr:")
    end

    it "is never successful" do
      expect(described_class.new(exit_code: 0)).not_to be_success
    end
  end

  describe E2B::TemplateError do
    it "records a source location and sets the backtrace from it" do
      error = described_class.new("bad template", source_location: "Dockerfile:3")
      expect(error.source_location).to eq("Dockerfile:3")
      expect(error.backtrace).to eq(["Dockerfile:3"])
    end
  end

  describe E2B::BuildError do
    it "records the failing step and source location" do
      error = described_class.new("build failed", step: "RUN make", source_location: "step:2")
      expect(error.step).to eq("RUN make")
      expect(error.source_location).to eq("step:2")
      expect(error.backtrace).to eq(["step:2"])
    end
  end
end
