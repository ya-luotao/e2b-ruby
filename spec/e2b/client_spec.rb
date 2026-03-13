# frozen_string_literal: true

require "spec_helper"

RSpec.describe E2B::Client do
  let(:http_client) { instance_double(E2B::API::HttpClient) }

  before do
    allow(ENV).to receive(:[]).and_call_original
    %w[E2B_API_KEY E2B_ACCESS_TOKEN E2B_API_URL E2B_DOMAIN E2B_DEBUG].each do |name|
      allow(ENV).to receive(:[]).with(name).and_return(nil)
    end
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
            envVars: { "RUBYOPT" => "-w" },
            secure: true,
            allow_internet_access: true,
            autoPause: false
          },
          timeout: 60
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
        .with(
          "/sandboxes",
          body: {
            templateID: "base",
            timeout: 17,
            secure: true,
            allow_internet_access: true,
            autoPause: false
          },
          timeout: 60
        )
        .and_return({ "sandboxID" => "sbx_123" })

      client = described_class.new(api_key: "api-key", sandbox_timeout_ms: 17_000)
      sandbox = client.create

      expect(sandbox.sandbox_id).to eq("sbx_123")
    end

    it "supports access-token authentication and preserves the configured domain" do
      expect(E2B::API::HttpClient).to receive(:new)
        .with(
          base_url: "https://api.team.e2b.test",
          api_key: nil,
          access_token: "access-token",
          logger: nil
        )
        .and_return(http_client)

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
          timeout: 60
        )
        .and_return({ "sandboxID" => "sbx_123" })

      client = described_class.new(access_token: "access-token", domain: "team.e2b.test")
      sandbox = client.create

      expect(sandbox.get_url(3000)).to eq("https://3000-sbx_123.team.e2b.test")
    end

    it "serializes lifecycle and network create options" do
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
            autoResume: { enabled: false }
          },
          timeout: 60
        )
        .and_return({
          "sandboxID" => "sbx_123",
          "trafficAccessToken" => "traffic-token"
        })

      client = described_class.new(api_key: "api-key")
      sandbox = client.create(
        secure: false,
        allow_internet_access: false,
        network: {
          deny_out: [E2B::ALL_TRAFFIC],
          allow_public_traffic: false
        },
        auto_pause: true
      )

      expect(sandbox.traffic_access_token).to eq("traffic-token")
    end

    it "defaults to the MCP template and starts the gateway when mcp is enabled" do
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
          timeout: 60
        )
        .and_return({ "sandboxID" => "sbx_123" })

      client = described_class.new(api_key: "api-key")
      sandbox = client.create(
        template: nil,
        mcp: {
          server: {
            url: "https://example.test"
          }
        }
      )

      expect(sandbox.get_mcp_url).to eq("https://50005-sbx_123.e2b.app/mcp")
    end

    it "kills unsupported templates and raises TemplateError for old envd versions" do
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
          timeout: 60
        )
        .and_return({ "sandboxID" => "sbx_123", "envdVersion" => "0.0.9" })
      expect(http_client).to receive(:delete).with("/sandboxes/sbx_123")

      client = described_class.new(api_key: "api-key")

      expect { client.create }
        .to raise_error(E2B::TemplateError, /update the template to use the new SDK/)
    end
  end

  describe "#connect" do
    it "uses the connect endpoint when no timeout override is provided" do
      allow(http_client).to receive(:post)
        .with("/sandboxes/sbx_123/connect", body: { timeout: 300 })
        .and_return({ "sandboxID" => "sbx_123" })

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
    it "returns a sandbox paginator with encoded metadata filters" do
      allow(http_client).to receive(:get)
        .with(
          "/v2/sandboxes",
          params: {
            limit: 2,
            metadata: "team=infra",
            state: ["running"]
          },
          detailed: true
        )
        .and_return(
          E2B::API::HttpClient::DetailedResponse.new(
            body: [
              { "sandboxID" => "sbx_1", "state" => "running" },
              { "sandboxID" => "sbx_2", "state" => "running" }
            ],
            headers: { "x-next-token" => "page-2" }
          )
        )

      client = described_class.new(api_key: "api-key")
      paginator = client.list(metadata: { team: "infra" }, state: "running", limit: 2)
      sandboxes = paginator.next_items

      expect(sandboxes.map(&:sandbox_id)).to eq(%w[sbx_1 sbx_2])
      expect(paginator.next_token).to eq("page-2")
    end
  end

  describe "#list_snapshots" do
    it "returns a snapshot paginator" do
      allow(http_client).to receive(:get)
        .with(
          "/snapshots",
          params: {
            sandboxID: "sbx_123",
            limit: 2
          },
          detailed: true
        )
        .and_return(
          E2B::API::HttpClient::DetailedResponse.new(
            body: [{ "snapshotID" => "snap_1" }],
            headers: {}
          )
        )

      client = described_class.new(api_key: "api-key")
      paginator = client.list_snapshots(sandbox_id: "sbx_123", limit: 2)
      snapshots = paginator.next_items

      expect(snapshots.map(&:snapshot_id)).to eq(["snap_1"])
      expect(paginator).not_to be_has_next
    end
  end

  describe "#create_snapshot" do
    it "wraps the created snapshot in SnapshotInfo" do
      allow(http_client).to receive(:post)
        .with("/sandboxes/sbx_123/snapshots")
        .and_return({ "snapshotID" => "snap_123" })

      client = described_class.new(api_key: "api-key")
      snapshot = client.create_snapshot("sbx_123")

      expect(snapshot).to be_a(E2B::Models::SnapshotInfo)
      expect(snapshot.snapshot_id).to eq("snap_123")
    end
  end

  describe "#delete_snapshot" do
    it "treats missing snapshots as not deleted" do
      allow(http_client).to receive(:delete).with("/templates/snap_missing").and_raise(E2B::NotFoundError, "missing")

      client = described_class.new(api_key: "api-key")

      expect(client.delete_snapshot("snap_missing")).to be(false)
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
