# frozen_string_literal: true

require "spec_helper"

RSpec.describe E2B::SandboxHelpers do
  # The helpers are private instance methods shared between Sandbox and Client.
  # This host exposes them for direct unit testing.
  let(:host_class) do
    Class.new do
      include E2B::SandboxHelpers

      # Re-export the private helpers as public for the specs.
      public(*E2B::SandboxHelpers.private_instance_methods)
    end
  end
  let(:host) { host_class.new }

  around do |example|
    saved = ENV.to_hash
    %w[E2B_API_KEY E2B_ACCESS_TOKEN E2B_DOMAIN E2B_API_URL].each { |k| ENV.delete(k) }
    example.run
  ensure
    ENV.replace(saved)
  end

  describe "#resolved_template" do
    it "returns an explicitly provided template unchanged" do
      expect(host.resolved_template("custom", mcp: false)).to eq("custom")
    end

    it "returns the MCP default template when mcp is requested and none given" do
      expect(host.resolved_template(nil, mcp: true)).to eq(E2B::Sandbox::DEFAULT_MCP_TEMPLATE)
    end

    it "falls back to the configured default, then 'base'" do
      expect(host.resolved_template(nil, mcp: false)).to eq("base")

      E2B.configure { |c| c.default_template = "configured" }
      expect(host.resolved_template("", mcp: false)).to eq("configured")
    end
  end

  describe "#normalized_lifecycle" do
    it "defaults to kill-on-timeout with no auto-resume" do
      expect(host.normalized_lifecycle(lifecycle: nil, auto_pause: false))
        .to eq(on_timeout: "kill", auto_resume: false)
    end

    it "uses pause-on-timeout when auto_pause is set" do
      expect(host.normalized_lifecycle(lifecycle: nil, auto_pause: true))
        .to eq(on_timeout: "pause", auto_resume: false)
    end

    it "honours an explicit lifecycle hash and keeps auto_resume only for pause" do
      expect(host.normalized_lifecycle(lifecycle: { on_timeout: "pause", auto_resume: true }, auto_pause: false))
        .to eq(on_timeout: "pause", auto_resume: true)

      # auto_resume is forced false when the sandbox is killed on timeout
      expect(host.normalized_lifecycle(lifecycle: { on_timeout: "kill", auto_resume: true }, auto_pause: false))
        .to eq(on_timeout: "kill", auto_resume: false)
    end

    it "raises on an invalid on_timeout value" do
      expect { host.normalized_lifecycle(lifecycle: { on_timeout: "explode" }, auto_pause: false) }
        .to raise_error(ArgumentError, /must be 'kill' or 'pause'/)
    end
  end

  describe "#resolve_credentials" do
    it "raises when no credentials can be resolved" do
      expect { host.resolve_credentials(api_key: nil, access_token: nil) }
        .to raise_error(E2B::ConfigurationError, /credentials are required/)
    end

    it "prefers explicit arguments" do
      expect(host.resolve_credentials(api_key: "explicit", access_token: nil))
        .to eq(api_key: "explicit", access_token: nil)
    end

    it "falls back to configuration then environment" do
      E2B.configure { |c| c.api_key = "config-key" }
      expect(host.resolve_credentials(api_key: nil, access_token: nil)[:api_key]).to eq("config-key")

      E2B.reset_configuration!
      ENV["E2B_ACCESS_TOKEN"] = "env-token"
      expect(host.resolve_credentials(api_key: nil, access_token: nil)[:access_token]).to eq("env-token")
    end
  end

  describe "#resolve_domain" do
    it "prefers argument, then config, then env, then default" do
      expect(host.resolve_domain("arg.dev")).to eq("arg.dev")

      E2B.configure { |c| c.domain = "config.dev" }
      expect(host.resolve_domain(nil)).to eq("config.dev")

      E2B.reset_configuration!
      ENV["E2B_DOMAIN"] = "env.dev"
      expect(host.resolve_domain(nil)).to eq("env.dev")

      ENV.delete("E2B_DOMAIN")
      expect(host.resolve_domain(nil)).to eq(E2B::Configuration::DEFAULT_DOMAIN)
    end
  end

  describe "#ensure_supported_envd_version!" do
    let(:http_client) { instance_double(E2B::API::HttpClient) }

    it "does nothing when no envd version is reported" do
      expect { host.ensure_supported_envd_version!({}, http_client) }.not_to raise_error
    end

    it "does nothing for a supported envd version" do
      expect { host.ensure_supported_envd_version!({ "envdVersion" => "0.2.0" }, http_client) }
        .not_to raise_error
    end

    it "deletes the sandbox and raises for an unsupported (old) envd version" do
      expect(http_client).to receive(:delete).with("/sandboxes/sbx_old")

      expect do
        host.ensure_supported_envd_version!(
          { "envdVersion" => "0.0.1", "sandboxID" => "sbx_old" }, http_client
        )
      end.to raise_error(E2B::TemplateError, /update the template/)
    end

    it "tolerates a NotFoundError while cleaning up the sandbox" do
      allow(http_client).to receive(:delete).and_raise(E2B::NotFoundError, "gone")

      expect do
        host.ensure_supported_envd_version!(
          { "envdVersion" => "0.0.1", "sandboxID" => "sbx_old" }, http_client
        )
      end.to raise_error(E2B::TemplateError)
    end
  end

  describe "#build_http_client" do
    it "constructs an API::HttpClient pointed at the domain-derived URL" do
      client = host.build_http_client(api_key: "k", access_token: nil, domain: "e2b.app")
      expect(client).to be_a(E2B::API::HttpClient)
    end
  end
end
