# frozen_string_literal: true

require "spec_helper"
require "base64"

RSpec.describe E2B::Services::BaseService do
  # Subclass that exposes the protected auth/version helpers for unit testing.
  let(:service_class) do
    Class.new(described_class) do
      def auth_headers(user) = user_auth_headers(user)
      def username(user) = resolve_username(user)
      def legacy_user? = legacy_default_user?
      def recursive_watch? = supports_recursive_watch?
    end
  end

  def build_service(envd_version: nil)
    service_class.new(
      sandbox_id: "sbx_1",
      sandbox_domain: "e2b.app",
      api_key: "key",
      envd_version: envd_version
    )
  end

  describe "#user_auth_headers" do
    it "builds a Basic auth header for an explicit user" do
      headers = build_service.auth_headers("alice")
      expect(headers).to eq("Authorization" => "Basic #{Base64.strict_encode64("alice:")}")
    end

    it "returns nil for a modern envd when no user is given" do
      expect(build_service(envd_version: "0.4.0").auth_headers(nil)).to be_nil
    end

    it "uses the default 'user' for a legacy envd when no user is given" do
      headers = build_service(envd_version: "0.3.9").auth_headers(nil)
      expect(headers).to eq("Authorization" => "Basic #{Base64.strict_encode64("user:")}")
    end
  end

  describe "#resolve_username" do
    it "returns the given user, the legacy default, or nil" do
      expect(build_service.username("bob")).to eq("bob")
      expect(build_service(envd_version: "0.3.0").username(nil)).to eq("user")
      expect(build_service(envd_version: "0.4.0").username(nil)).to be_nil
    end
  end

  describe "#legacy_default_user?" do
    it "is false without a version, true below 0.4.0, false at/above" do
      expect(build_service.legacy_user?).to be(false)
      expect(build_service(envd_version: "0.3.9").legacy_user?).to be(true)
      expect(build_service(envd_version: "0.4.0").legacy_user?).to be(false)
    end

    it "is false for an unparseable version" do
      expect(build_service(envd_version: "not-a-version").legacy_user?).to be(false)
    end
  end

  describe "#supports_recursive_watch?" do
    it "is true without a version, false below 0.1.4, true at/above" do
      expect(build_service.recursive_watch?).to be(true)
      expect(build_service(envd_version: "0.1.3").recursive_watch?).to be(false)
      expect(build_service(envd_version: "0.1.4").recursive_watch?).to be(true)
    end

    it "is true (permissive) for an unparseable version" do
      expect(build_service(envd_version: "weird").recursive_watch?).to be(true)
    end
  end
end
