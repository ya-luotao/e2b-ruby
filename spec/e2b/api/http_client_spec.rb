# frozen_string_literal: true

require "spec_helper"

RSpec.describe E2B::API::HttpClient do
  subject(:client) { described_class.new(base_url: base_url, api_key: api_key, access_token: access_token) }

  let(:base_url) { "https://api.example.test" }
  let(:api_key) { "test-key" }
  let(:access_token) { nil }

  describe "#get" do
    it "parses JSON string responses when the content type is JSON" do
      stub_request(:get, "#{base_url}/sandboxes")
        .to_return(
          status: 200,
          body: '{"sandboxID":"sbx_123"}',
          headers: { "Content-Type" => "application/json" }
        )

      expect(client.get("/sandboxes")).to eq({ "sandboxID" => "sbx_123" })
    end

    it "parses JSON-looking strings even without a JSON content type" do
      stub_request(:get, "#{base_url}/health")
        .to_return(
          status: 200,
          body: '{"ok":true}',
          headers: { "Content-Type" => "text/plain" }
        )

      expect(client.get("/health")).to eq({ "ok" => true })
    end

    it "sends bearer authorization when initialized with an access token" do
      stub_request(:get, "#{base_url}/sandboxes")
        .with(headers: { "Authorization" => "Bearer access-token" })
        .to_return(
          status: 200,
          body: '{"sandboxID":"sbx_123"}',
          headers: { "Content-Type" => "application/json" }
        )

      described_class.new(base_url: base_url, access_token: "access-token").get("/sandboxes")

      expect(a_request(:get, "#{base_url}/sandboxes")
        .with(headers: { "Authorization" => "Bearer access-token" })).to have_been_made
    end
  end

  describe "error mapping" do
    {
      401 => E2B::AuthenticationError,
      403 => E2B::AuthenticationError,
      404 => E2B::NotFoundError,
      409 => E2B::ConflictError,
      429 => E2B::RateLimitError,
      500 => E2B::E2BError
    }.each do |status, error_class|
      it "raises #{error_class} for HTTP #{status}" do
        stub_request(:get, "#{base_url}/sandboxes/sbx_123")
          .to_return(
            status: status,
            body: { message: "boom" }.to_json,
            headers: {
              "Content-Type" => "application/json",
              "X-Trace-Id" => "trace-123"
            }
          )

        expect { client.get("/sandboxes/sbx_123") }
          .to raise_error(error_class) { |error|
            expect(error.message).to eq("boom")
            expect(error.status_code).to eq(status)
            expect(error.headers["x-trace-id"]).to eq("trace-123")
          }
      end
    end
  end

  describe "network failures" do
    let(:connection) { instance_double(Faraday::Connection) }

    before do
      client.instance_variable_set(:@connection, connection)
    end

    it "wraps Faraday timeouts in E2B::TimeoutError" do
      allow(connection).to receive(:get).and_raise(Faraday::TimeoutError, "execution expired")

      expect { client.get("/slow") }
        .to raise_error(E2B::TimeoutError, /Request timed out: execution expired/)
    end

    it "wraps Faraday connection failures in E2B::E2BError" do
      allow(connection).to receive(:get).and_raise(Faraday::ConnectionFailed, "connection refused")

      expect { client.get("/offline") }
        .to raise_error(E2B::E2BError, /Connection failed: connection refused/)
    end
  end
end
