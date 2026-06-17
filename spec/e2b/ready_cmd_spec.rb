# frozen_string_literal: true

require "spec_helper"

RSpec.describe E2B::ReadyCmd do
  it "exposes the wrapped command via get_cmd" do
    expect(described_class.new("echo hi").get_cmd).to eq("echo hi")
  end

  describe "E2B ready command helpers" do
    it "builds a port-listening check" do
      expect(E2B.wait_for_port(8080).get_cmd).to eq("ss -tuln | grep :8080")
    end

    it "builds a URL status-code check" do
      cmd = E2B.wait_for_url("http://localhost:3000").get_cmd
      expect(cmd).to include("curl").and include("http://localhost:3000").and include('grep -q "200"')
    end

    it "allows a custom expected status code" do
      expect(E2B.wait_for_url("http://x", 204).get_cmd).to include('grep -q "204"')
    end

    it "builds a process check" do
      expect(E2B.wait_for_process("nginx").get_cmd).to eq("pgrep nginx > /dev/null")
    end

    it "builds a file-existence check" do
      expect(E2B.wait_for_file("/tmp/ready").get_cmd).to eq("[ -f /tmp/ready ]")
    end

    describe ".wait_for_timeout" do
      it "converts milliseconds to whole seconds" do
        expect(E2B.wait_for_timeout(5000).get_cmd).to eq("sleep 5")
      end

      it "clamps to a minimum of one second" do
        expect(E2B.wait_for_timeout(100).get_cmd).to eq("sleep 1")
      end
    end
  end
end
