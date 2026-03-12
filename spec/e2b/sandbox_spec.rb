# frozen_string_literal: true

require "spec_helper"

RSpec.describe E2B::Sandbox do
  let(:http_client) { instance_double(E2B::API::HttpClient) }

  before do
    allow(ENV).to receive(:[]).and_call_original
    %w[E2B_API_KEY E2B_ACCESS_TOKEN E2B_API_URL E2B_DOMAIN E2B_DEBUG].each do |name|
      allow(ENV).to receive(:[]).with(name).and_return(nil)
    end
  end

  describe ".create" do
    it "posts the create payload and returns a hydrated sandbox" do
      expect(E2B::API::HttpClient).to receive(:new)
        .with(
          base_url: "https://api.custom.e2b.test",
          api_key: "api-key",
          access_token: nil,
          logger: nil
        )
        .and_return(http_client)

      allow(http_client).to receive(:post)
        .with(
          "/sandboxes",
          body: {
            templateID: "base",
            timeout: 600,
            metadata: { "env" => "test" },
            envVars: { "FOO" => "bar" }
          },
          timeout: 45
        )
        .and_return(
          {
            "sandboxID" => "sbx_123",
            "templateID" => "base",
            "alias" => "runner",
            "metadata" => { "env" => "test" },
            "envdAccessToken" => "envd-token",
            "domain" => "remote.e2b.test"
          }
        )

      sandbox = described_class.create(
        timeout: 600,
        metadata: { "env" => "test" },
        envs: { "FOO" => "bar" },
        api_key: "api-key",
        domain: "custom.e2b.test",
        request_timeout: 45
      )

      expect(sandbox.sandbox_id).to eq("sbx_123")
      expect(sandbox.alias_name).to eq("runner")
      expect(sandbox.metadata).to eq({ "env" => "test" })
      expect(sandbox.get_url(3000)).to eq("https://3000-sbx_123.remote.e2b.test")
    end

    it "accepts access-token authentication without an API key" do
      expect(E2B::API::HttpClient).to receive(:new)
        .with(
          base_url: "https://api.e2b.app",
          api_key: nil,
          access_token: "access-token",
          logger: nil
        )
        .and_return(http_client)

      allow(http_client).to receive(:post).and_return({ "sandboxID" => "sbx_123" })

      sandbox = described_class.create(access_token: "access-token")

      expect(sandbox.sandbox_id).to eq("sbx_123")
    end
  end

  describe ".connect" do
    before do
      allow(E2B::API::HttpClient).to receive(:new).and_return(http_client)
    end

    it "uses the connect endpoint even when no timeout is provided" do
      allow(http_client).to receive(:post)
        .with("/sandboxes/sbx_123/connect", body: { timeout: 300 })
        .and_return({ "sandboxID" => "sbx_123" })

      sandbox = described_class.connect("sbx_123", api_key: "api-key")

      expect(sandbox.sandbox_id).to eq("sbx_123")
    end

    it "uses the connect endpoint when a timeout is provided" do
      allow(http_client).to receive(:post)
        .with("/sandboxes/sbx_123/connect", body: { timeout: 30 })
        .and_return({
          "sandboxID" => "sbx_123",
          "endAt" => "2026-03-12T01:00:00Z",
          "domain" => "resume.e2b.test"
        })

      sandbox = described_class.connect("sbx_123", timeout: 30, api_key: "api-key")

      expect(sandbox.end_at).to eq(Time.parse("2026-03-12T01:00:00Z"))
      expect(sandbox.get_url(8080)).to eq("https://8080-sbx_123.resume.e2b.test")
    end
  end

  describe ".list" do
    before do
      allow(E2B::API::HttpClient).to receive(:new).and_return(http_client)
    end

    it "serializes metadata filters and returns sandbox payloads" do
      allow(http_client).to receive(:get)
        .with(
          "/v2/sandboxes",
          params: {
            limit: 5,
            nextToken: "page-2",
            metadata: '{"team":"sdk"}',
            state: "running"
          }
        )
        .and_return({ "sandboxes" => [{ "sandboxID" => "sbx_123" }] })

      sandboxes = described_class.list(
        query: { metadata: { team: "sdk" }, state: "running" },
        limit: 5,
        next_token: "page-2",
        api_key: "api-key"
      )

      expect(sandboxes).to eq([{ "sandboxID" => "sbx_123" }])
    end
  end

  describe "#set_timeout" do
    subject(:sandbox) do
      described_class.new(
        sandbox_data: { "sandboxID" => "sbx_123" },
        http_client: http_client,
        api_key: "api-key"
      )
    end

    it "rejects invalid timeout values" do
      expect { sandbox.set_timeout(0) }.to raise_error(ArgumentError, "Timeout must be positive")
      expect { sandbox.set_timeout(86_401) }
        .to raise_error(ArgumentError, "Timeout cannot exceed 24 hours (86400s)")
    end

    it "posts the timeout update and refreshes the local deadline" do
      now = Time.parse("2026-03-12T00:00:00Z")
      allow(Time).to receive(:now).and_return(now)
      allow(http_client).to receive(:post).with("/sandboxes/sbx_123/timeout", body: { timeout: 120 })

      sandbox.set_timeout(120)

      expect(sandbox.end_at).to eq(now + 120)
    end
  end

  describe "#running?" do
    subject(:sandbox) do
      described_class.new(
        sandbox_data: {
          "sandboxID" => "sbx_123",
          "endAt" => "2026-03-12T00:00:00Z"
        },
        http_client: http_client,
        api_key: "api-key"
      )
    end

    it "returns false without hitting the API when the sandbox is already expired" do
      allow(Time).to receive(:now).and_return(Time.parse("2026-03-12T00:05:00Z"))
      expect(http_client).not_to receive(:get)

      expect(sandbox.running?).to be(false)
    end

    it "returns false when get_info raises an API error" do
      allow(Time).to receive(:now).and_return(Time.parse("2026-03-11T23:59:00Z"))
      allow(http_client).to receive(:get).with("/sandboxes/sbx_123").and_raise(E2B::NotFoundError, "gone")

      expect(sandbox.running?).to be(false)
    end
  end

  describe "#logs" do
    subject(:sandbox) do
      described_class.new(
        sandbox_data: { "sandboxID" => "sbx_123" },
        http_client: http_client,
        api_key: "api-key"
      )
    end

    it "unwraps the logs array from hash responses" do
      start_time = Time.parse("2026-03-12T00:00:00Z")
      allow(http_client).to receive(:get)
        .with(
          "/sandboxes/sbx_123/logs",
          params: { limit: 2, start: start_time.iso8601 }
        )
        .and_return({ "logs" => [{ "message" => "booted" }] })

      expect(sandbox.logs(start_time: start_time, limit: 2)).to eq([{ "message" => "booted" }])
    end
  end

  describe "#download_url" do
    subject(:sandbox) do
      described_class.new(
        sandbox_data: { "sandboxID" => "sbx_123" },
        http_client: http_client,
        api_key: "api-key",
        domain: "custom.e2b.test"
      )
    end

    it "URL-encodes the path and optional username" do
      expect(sandbox.download_url("/tmp/my file.txt", user: "dev user"))
        .to eq("https://49983-sbx_123.custom.e2b.test/files?path=%2Ftmp%2Fmy+file.txt&username=dev+user")
    end
  end
end
