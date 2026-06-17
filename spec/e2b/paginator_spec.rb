# frozen_string_literal: true

require "spec_helper"

RSpec.describe E2B::BasePaginator do
  it "fetches pages, advances the token, and stops when the token is blank" do
    pages = [
      [%w[a b], "token-2"],
      [%w[c d], ""]
    ]
    paginator = described_class.new(limit: 2) do |limit:, next_token:|
      expect(limit).to eq(2)
      pages.shift.tap { |page| expect(page).not_to(be_nil, "fetched more pages than expected (next_token=#{next_token})") }
    end

    expect(paginator.has_next?).to be(true)
    expect(paginator.next_items).to eq(%w[a b])
    expect(paginator.next_token).to eq("token-2")
    expect(paginator.has_next?).to be(true)

    expect(paginator.next_items).to eq(%w[c d])
    expect(paginator.has_next?).to be(false)
  end

  it "raises once exhausted" do
    paginator = described_class.new(limit: 1) { |**| [[], nil] }
    paginator.next_items
    expect { paginator.next_items }.to raise_error(E2B::E2BError, /No more items/)
  end

  describe E2B::SandboxPaginator do
    let(:response) do
      instance_double(
        E2B::API::HttpClient::DetailedResponse,
        body: { "sandboxes" => [{ "sandboxID" => "sbx_1" }] },
        headers: { "x-next-token" => "next-1" }
      )
    end
    let(:http_client) { instance_double(E2B::API::HttpClient) }

    it "builds SandboxInfo objects and reads the next token from headers" do
      expect(http_client).to receive(:get)
        .with("/v2/sandboxes", params: { limit: 100 }, detailed: true)
        .and_return(response)

      paginator = described_class.new(http_client: http_client)
      items = paginator.next_items

      expect(items.first).to be_a(E2B::Models::SandboxInfo)
      expect(items.first.sandbox_id).to eq("sbx_1")
      expect(paginator.next_token).to eq("next-1")
    end

    it "encodes metadata and state query params" do
      expect(http_client).to receive(:get) do |_path, params:, detailed:|
        expect(detailed).to be(true)
        expect(params[:metadata]).to eq("env=prod")
        expect(params[:state]).to eq(["running"])
        response
      end

      described_class.new(
        http_client: http_client,
        query: { metadata: { env: "prod" }, state: "running" }
      ).next_items
    end

    it "handles a bare-array response body" do
      array_response = instance_double(
        E2B::API::HttpClient::DetailedResponse,
        body: [{ "sandboxID" => "sbx_2" }],
        headers: {}
      )
      allow(http_client).to receive(:get).and_return(array_response)

      items = described_class.new(http_client: http_client).next_items
      expect(items.first.sandbox_id).to eq("sbx_2")
    end

    describe ".encode_metadata" do
      it "encodes metadata pairs into a query string" do
        expect(described_class.encode_metadata({ "env" => "prod" })).to eq("env=prod")
        expect(described_class.encode_metadata({ env: "prod", tier: "free" })).to eq("env=prod&tier=free")
      end
    end
  end

  describe E2B::SnapshotPaginator do
    it "builds SnapshotInfo objects and passes the sandbox id filter" do
      response = instance_double(
        E2B::API::HttpClient::DetailedResponse,
        body: [{ "snapshotID" => "snap_1" }],
        headers: { "x-next-token" => nil }
      )
      http_client = instance_double(E2B::API::HttpClient)

      expect(http_client).to receive(:get)
        .with("/snapshots", params: { limit: 100, sandboxID: "sbx_1" }, detailed: true)
        .and_return(response)

      paginator = described_class.new(http_client: http_client, sandbox_id: "sbx_1")
      items = paginator.next_items

      expect(items.first).to be_a(E2B::Models::SnapshotInfo)
      expect(items.first.snapshot_id).to eq("snap_1")
      expect(paginator.has_next?).to be(false)
    end
  end
end
