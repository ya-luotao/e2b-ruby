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
            envVars: { "FOO" => "bar" },
            secure: true,
            allow_internet_access: true,
            autoPause: false
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

    it "serializes lifecycle and network create options and exposes returned traffic access data" do
      expect(E2B::API::HttpClient).to receive(:new).and_return(http_client)

      allow(http_client).to receive(:post)
        .with(
          "/sandboxes",
          body: {
            templateID: "base",
            timeout: 300,
            secure: false,
            allow_internet_access: false,
            network: {
              deny_out: [E2B::ALL_TRAFFIC],
              allow_public_traffic: false
            },
            autoPause: true,
            autoResume: { enabled: true }
          },
          timeout: 120
        )
        .and_return(
          {
            "sandboxID" => "sbx_123",
            "state" => "running",
            "envdVersion" => "0.2.0",
            "trafficAccessToken" => "traffic-token"
          }
        )

      sandbox = described_class.create(
        api_key: "api-key",
        secure: false,
        allow_internet_access: false,
        network: {
          deny_out: [E2B::ALL_TRAFFIC],
          allow_public_traffic: false
        },
        lifecycle: { on_timeout: "pause", auto_resume: true }
      )

      expect(sandbox.state).to eq("running")
      expect(sandbox.envd_version).to eq("0.2.0")
      expect(sandbox.traffic_access_token).to eq("traffic-token")
    end

    it "defaults to the MCP template and starts the gateway when mcp is enabled" do
      expect(E2B::API::HttpClient).to receive(:new).and_return(http_client)
      allow(SecureRandom).to receive(:uuid).and_return("mcp-token")
      expect_any_instance_of(E2B::Services::Commands).to receive(:run)
        .with(
          "mcp-gateway --config \\{\\\"server\\\":\\{\\\"url\\\":\\\"https://example.test\\\"\\}\\}",
          user: "root",
          envs: { "GATEWAY_ACCESS_TOKEN" => "mcp-token" }
        )
        .and_return(E2B::Services::CommandResult.new(exit_code: 0))

      allow(http_client).to receive(:post)
        .with(
          "/sandboxes",
          body: {
            templateID: "mcp-gateway",
            timeout: 300,
            secure: true,
            allow_internet_access: true,
            autoPause: false,
            mcp: {
              server: {
                url: "https://example.test"
              }
            }
          },
          timeout: 120
        )
        .and_return({ "sandboxID" => "sbx_123", "domain" => "remote.e2b.test" })

      sandbox = described_class.create(
        api_key: "api-key",
        template: nil,
        mcp: {
          server: {
            url: "https://example.test"
          }
        }
      )

      expect(sandbox.get_mcp_url).to eq("https://50005-sbx_123.remote.e2b.test/mcp")
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

    it "kills unsupported templates and raises TemplateError for old envd versions" do
      expect(E2B::API::HttpClient).to receive(:new).and_return(http_client)
      allow(http_client).to receive(:post)
        .with(
          "/sandboxes",
          body: {
            templateID: "base",
            timeout: 300,
            secure: true,
            allow_internet_access: true,
            autoPause: false
          },
          timeout: 120
        )
        .and_return({ "sandboxID" => "sbx_123", "envdVersion" => "0.0.9" })
      expect(http_client).to receive(:delete).with("/sandboxes/sbx_123")

      expect { described_class.create(api_key: "api-key") }
        .to raise_error(E2B::TemplateError, /update the template to use the new SDK/)
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

    it "returns a paginator that encodes metadata filters and state arrays" do
      allow(http_client).to receive(:get)
        .with(
          "/v2/sandboxes",
          params: {
            limit: 5,
            nextToken: "page-2",
            metadata: "team=sdk",
            state: %w[running paused]
          },
          detailed: true
        )
        .and_return(
          E2B::API::HttpClient::DetailedResponse.new(
            body: [{ "sandboxID" => "sbx_123", "state" => "running" }],
            headers: { "x-next-token" => "page-3" }
          )
        )

      paginator = described_class.list(
        query: { metadata: { team: "sdk" }, state: %w[running paused] },
        limit: 5,
        next_token: "page-2",
        api_key: "api-key"
      )

      sandboxes = paginator.next_items

      expect(sandboxes.map(&:sandbox_id)).to eq(["sbx_123"])
      expect(sandboxes.first.state).to eq("running")
      expect(paginator.next_token).to eq("page-3")
      expect(paginator).to be_has_next
    end
  end

  describe ".list_snapshots" do
    before do
      allow(E2B::API::HttpClient).to receive(:new).and_return(http_client)
    end

    it "returns a paginator for snapshots filtered by sandbox" do
      allow(http_client).to receive(:get)
        .with(
          "/snapshots",
          params: {
            sandboxID: "sbx_123",
            limit: 2,
            nextToken: "snap-page-2"
          },
          detailed: true
        )
        .and_return(
          E2B::API::HttpClient::DetailedResponse.new(
            body: [{ "snapshotID" => "snap_123" }],
            headers: { "x-next-token" => "snap-page-3" }
          )
        )

      paginator = described_class.list_snapshots(
        sandbox_id: "sbx_123",
        limit: 2,
        next_token: "snap-page-2",
        api_key: "api-key"
      )

      snapshots = paginator.next_items

      expect(snapshots.map(&:snapshot_id)).to eq(["snap_123"])
      expect(paginator.next_token).to eq("snap-page-3")
    end

    it "returns false when deleting a missing snapshot" do
      allow(http_client).to receive(:delete).with("/templates/snap_missing").and_raise(E2B::NotFoundError, "missing")

      expect(described_class.delete_snapshot("snap_missing", api_key: "api-key")).to be(false)
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

    it "returns false when the control plane reports the sandbox as paused" do
      allow(Time).to receive(:now).and_return(Time.parse("2026-03-11T23:59:00Z"))
      allow(http_client).to receive(:get).with("/sandboxes/sbx_123").and_return(
        {
          "sandboxID" => "sbx_123",
          "state" => "paused",
          "endAt" => "2026-03-12T00:00:00Z"
        }
      )

      expect(sandbox.running?).to be(false)
      expect(sandbox.state).to eq("paused")
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

  describe "#create_snapshot" do
    subject(:sandbox) do
      described_class.new(
        sandbox_data: { "sandboxID" => "sbx_123" },
        http_client: http_client,
        api_key: "api-key"
      )
    end

    it "returns snapshot info objects" do
      allow(http_client).to receive(:post)
        .with("/sandboxes/sbx_123/snapshots")
        .and_return({ "snapshotID" => "snap_123" })

      snapshot = sandbox.create_snapshot

      expect(snapshot).to be_a(E2B::Models::SnapshotInfo)
      expect(snapshot.snapshot_id).to eq("snap_123")
    end
  end

  describe "#connect" do
    subject(:sandbox) do
      described_class.new(
        sandbox_data: { "sandboxID" => "sbx_123" },
        http_client: http_client,
        api_key: "api-key"
      )
    end

    it "reuses the connect endpoint and returns self" do
      allow(http_client).to receive(:post)
        .with("/sandboxes/sbx_123/connect", body: { timeout: 30 })
        .and_return({ "sandboxID" => "sbx_123", "state" => "running" })

      expect(sandbox.connect(timeout: 30)).to equal(sandbox)
      expect(sandbox.state).to eq("running")
    end
  end

  describe "#get_mcp_token" do
    subject(:sandbox) do
      described_class.new(
        sandbox_data: { "sandboxID" => "sbx_123" },
        http_client: http_client,
        api_key: "api-key"
      )
    end

    it "memoizes the token read from the gateway file" do
      allow(sandbox.files).to receive(:read)
        .with("/etc/mcp-gateway/.token", user: "root")
        .and_return("persisted-token")

      expect(sandbox.get_mcp_token).to eq("persisted-token")
      expect(sandbox.get_mcp_token).to eq("persisted-token")
      expect(sandbox.files).to have_received(:read).once
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

    it "uses the default username in file URLs for older envd versions" do
      legacy_sandbox = described_class.new(
        sandbox_data: {
          "sandboxID" => "sbx_123",
          "envdVersion" => "0.3.9"
        },
        http_client: http_client,
        api_key: "api-key",
        domain: "custom.e2b.test"
      )

      expect(legacy_sandbox.download_url("/tmp/my file.txt"))
        .to eq("https://49983-sbx_123.custom.e2b.test/files?path=%2Ftmp%2Fmy+file.txt&username=user")
    end

    it "signs file URLs for secured sandboxes" do
      secure_sandbox = described_class.new(
        sandbox_data: {
          "sandboxID" => "sbx_123",
          "envdAccessToken" => "envd-token"
        },
        http_client: http_client,
        api_key: "api-key",
        domain: "custom.e2b.test"
      )

      allow(Time).to receive(:now).and_return(Time.at(1_700_000_000))

      expect(secure_sandbox.download_url("/tmp/my file.txt", user: "dev user", use_signature_expiration: 60))
        .to eq("https://49983-sbx_123.custom.e2b.test/files?path=%2Ftmp%2Fmy+file.txt&username=dev+user&signature=v1_mhCcPjgi%2BL9J%2F0NjgKNfvmhRNfUNJIReQ9F4SnmGj3Q&signature_expiration=1700000060")
    end

    it "signs upload URLs for secured sandboxes" do
      secure_sandbox = described_class.new(
        sandbox_data: {
          "sandboxID" => "sbx_123",
          "envdAccessToken" => "envd-token"
        },
        http_client: http_client,
        api_key: "api-key",
        domain: "custom.e2b.test"
      )

      allow(Time).to receive(:now).and_return(Time.at(1_700_000_000))

      expect(secure_sandbox.upload_url("/tmp/my file.txt", user: "dev user", use_signature_expiration: 60))
        .to eq("https://49983-sbx_123.custom.e2b.test/files?path=%2Ftmp%2Fmy+file.txt&username=dev+user&signature=v1_a%2FxNf3cifN6uo%2FKzZth1RPnUHdo%2BkpEzkenZ%2BzC8Uzo&signature_expiration=1700000060")
    end

    it "rejects signature expiration for unsecured sandboxes" do
      expect { sandbox.download_url("/tmp/my file.txt", use_signature_expiration: 60) }
        .to raise_error(ArgumentError, "Signature expiration can be used only when the sandbox is secured")
    end
  end
end
