# frozen_string_literal: true

require "spec_helper"

RSpec.describe E2B::Configuration do
  around do |example|
    # Isolate the process environment so env-var precedence specs are deterministic.
    saved = ENV.to_hash
    %w[E2B_API_KEY E2B_ACCESS_TOKEN E2B_DOMAIN E2B_API_URL E2B_DEBUG].each { |k| ENV.delete(k) }
    example.run
  ensure
    ENV.replace(saved)
  end

  describe "#initialize defaults and env vars" do
    it "uses built-in defaults when nothing is provided" do
      config = described_class.new
      expect(config.domain).to eq(described_class::DEFAULT_DOMAIN)
      expect(config.api_url).to eq("https://api.#{described_class::DEFAULT_DOMAIN}")
      expect(config.request_timeout).to eq(described_class::DEFAULT_REQUEST_TIMEOUT)
      expect(config.debug).to be(false)
    end

    it "reads credentials and domain from environment variables" do
      ENV["E2B_API_KEY"] = "env-key"
      ENV["E2B_ACCESS_TOKEN"] = "env-token"
      ENV["E2B_DOMAIN"] = "custom.dev"

      config = described_class.new
      expect(config.api_key).to eq("env-key")
      expect(config.access_token).to eq("env-token")
      expect(config.domain).to eq("custom.dev")
      expect(config.api_url).to eq("https://api.custom.dev")
    end

    it "prefers explicit arguments over environment variables" do
      ENV["E2B_API_KEY"] = "env-key"
      config = described_class.new(api_key: "explicit-key")
      expect(config.api_key).to eq("explicit-key")
    end

    it "enables debug from E2B_DEBUG=true and points api_url at localhost" do
      ENV["E2B_DEBUG"] = "true"
      config = described_class.new
      expect(config.debug).to be(true)
      expect(config.api_url).to eq("http://localhost:3000")
    end

    it "honours an explicit E2B_API_URL over the domain-derived URL" do
      ENV["E2B_API_URL"] = "https://proxy.internal"
      expect(described_class.new.api_url).to eq("https://proxy.internal")
    end
  end

  describe "#validate!" do
    it "raises ConfigurationError when neither api_key nor access_token is set" do
      expect { described_class.new.validate! }
        .to raise_error(E2B::ConfigurationError, /API key is required/)
    end

    it "does not raise when an api_key is present" do
      expect { described_class.new(api_key: "k").validate! }.not_to raise_error
    end

    it "does not raise when only an access_token is present" do
      expect { described_class.new(access_token: "t").validate! }.not_to raise_error
    end
  end

  describe "#valid?" do
    it "is true with credentials and false without" do
      expect(described_class.new(api_key: "k")).to be_valid
      expect(described_class.new(access_token: "t")).to be_valid
      expect(described_class.new).not_to be_valid
      expect(described_class.new(api_key: "")).not_to be_valid
    end
  end

  describe ".default_api_url" do
    it "returns localhost in debug mode and the domain URL otherwise" do
      expect(described_class.default_api_url("e2b.app", debug: true)).to eq("http://localhost:3000")
      expect(described_class.default_api_url("e2b.app")).to eq("https://api.e2b.app")
    end
  end
end
