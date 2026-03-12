# frozen_string_literal: true

require "spec_helper"

RSpec.describe E2B::Client do
  let(:http_client) { instance_double(E2B::API::HttpClient) }

  before do
    allow(E2B::API::HttpClient).to receive(:new).and_return(http_client)
  end

  describe "#create" do
    it "converts timeout_ms to timeout seconds and builds a sandbox" do
      allow(http_client).to receive(:post)
        .with(
          "/sandboxes",
          body: {
            templateID: "python",
            timeout: 9,
            metadata: { "purpose" => "test" },
            envVars: { "RUBYOPT" => "-w" }
          },
          timeout: 120
        )
        .and_return(
          {
            "sandboxID" => "sbx_123",
            "templateID" => "python",
            "metadata" => { "purpose" => "test" }
          }
        )

      client = described_class.new(api_key: "api-key")
      sandbox = client.create(
        template: "python",
        timeout_ms: 9500,
        metadata: { "purpose" => "test" },
        envs: { "RUBYOPT" => "-w" }
      )

      expect(sandbox).to be_a(E2B::Sandbox)
      expect(sandbox.sandbox_id).to eq("sbx_123")
      expect(sandbox.template_id).to eq("python")
      expect(sandbox.metadata).to eq({ "purpose" => "test" })
    end

    it "falls back to the configured sandbox timeout when no timeout is provided" do
      allow(http_client).to receive(:post)
        .with("/sandboxes", body: { templateID: "base", timeout: 17 }, timeout: 120)
        .and_return({ "sandboxID" => "sbx_123" })

      client = described_class.new(api_key: "api-key", sandbox_timeout_ms: 17_000)
      sandbox = client.create

      expect(sandbox.sandbox_id).to eq("sbx_123")
    end
  end

  describe "#connect" do
    it "uses GET when no timeout override is provided" do
      allow(http_client).to receive(:get).with("/sandboxes/sbx_123").and_return({ "sandboxID" => "sbx_123" })

      client = described_class.new(api_key: "api-key")
      sandbox = client.connect("sbx_123")

      expect(sandbox.sandbox_id).to eq("sbx_123")
    end

    it "uses the connect endpoint when timeout is provided" do
      allow(http_client).to receive(:post)
        .with("/sandboxes/sbx_123/connect", body: { timeout: 30 })
        .and_return({ "sandboxID" => "sbx_123", "endAt" => "2026-03-12T00:00:30Z" })

      client = described_class.new(api_key: "api-key")
      sandbox = client.connect("sbx_123", timeout: 30)

      expect(sandbox.end_at).to eq(Time.parse("2026-03-12T00:00:30Z"))
    end
  end

  describe "#list" do
    it "serializes filters and wraps sandbox hashes in Sandbox objects" do
      allow(http_client).to receive(:get)
        .with(
          "/v2/sandboxes",
          params: {
            limit: 2,
            metadata: '{"team":"infra"}',
            state: "running"
          }
        )
        .and_return(
          {
            "sandboxes" => [
              { "sandboxID" => "sbx_1" },
              { "sandboxID" => "sbx_2" }
            ]
          }
        )

      client = described_class.new(api_key: "api-key")
      sandboxes = client.list(metadata: { team: "infra" }, state: "running", limit: 2)

      expect(sandboxes.map(&:sandbox_id)).to eq(%w[sbx_1 sbx_2])
    end
  end

  describe "#kill" do
    it "treats missing sandboxes as successfully removed" do
      allow(http_client).to receive(:delete).with("/sandboxes/sbx_missing").and_raise(E2B::NotFoundError, "missing")

      client = described_class.new(api_key: "api-key")

      expect(client.kill("sbx_missing")).to be(true)
    end
  end
end
