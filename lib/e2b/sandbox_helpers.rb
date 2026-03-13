# frozen_string_literal: true

require "shellwords"

module E2B
  # Shared helpers used by both Sandbox class methods and Client.
  #
  # These methods are duplicated across both entry points to preserve
  # the dual API surface (Sandbox.create vs Client#create). This module
  # keeps them in a single place.
  module SandboxHelpers
    private

    def resolved_template(template, mcp:)
      return template unless template.nil? || template.empty?

      return Sandbox::DEFAULT_MCP_TEMPLATE if mcp

      E2B.configuration&.default_template || "base"
    end

    def normalized_lifecycle(lifecycle:, auto_pause:)
      raw_lifecycle = lifecycle || {
        on_timeout: auto_pause ? "pause" : "kill",
        auto_resume: false
      }

      on_timeout = raw_lifecycle[:on_timeout] || raw_lifecycle["on_timeout"] || "kill"
      unless %w[kill pause].include?(on_timeout)
        raise ArgumentError, "Lifecycle on_timeout must be 'kill' or 'pause'"
      end

      auto_resume = if raw_lifecycle.key?(:auto_resume)
                      raw_lifecycle[:auto_resume]
                    else
                      raw_lifecycle["auto_resume"]
                    end

      {
        on_timeout: on_timeout,
        auto_resume: on_timeout == "pause" ? !!auto_resume : false
      }
    end

    def start_mcp_gateway(sandbox, mcp)
      token = SecureRandom.uuid
      sandbox.instance_variable_set(:@mcp_token, token)
      sandbox.commands.run(
        "mcp-gateway --config #{Shellwords.shellescape(JSON.generate(mcp))}",
        user: "root",
        envs: { "GATEWAY_ACCESS_TOKEN" => token }
      )
    end

    def ensure_supported_envd_version!(response, http_client)
      envd_version = response["envdVersion"] || response["envd_version"] || response[:envdVersion]
      return if envd_version.nil?
      return unless Gem::Version.new(envd_version) < Gem::Version.new("0.1.0")

      sandbox_id = response["sandboxID"] || response["sandbox_id"] || response[:sandboxID]
      begin
        http_client.delete("/sandboxes/#{sandbox_id}") if sandbox_id
      rescue NotFoundError
        nil
      end

      raise TemplateError,
        "You need to update the template to use the new SDK. You can do this by running `e2b template build` in the directory with the template."
    rescue ArgumentError
      nil
    end

    def resolve_credentials(api_key:, access_token:)
      resolved_api_key = api_key || E2B.configuration&.api_key || ENV["E2B_API_KEY"]
      resolved_access_token = access_token || E2B.configuration&.access_token || ENV["E2B_ACCESS_TOKEN"]

      unless (resolved_api_key && !resolved_api_key.empty?) || (resolved_access_token && !resolved_access_token.empty?)
        raise ConfigurationError,
          "E2B credentials are required. Set E2B_API_KEY or E2B_ACCESS_TOKEN, or pass api_key:/access_token:."
      end

      { api_key: resolved_api_key, access_token: resolved_access_token }
    end

    def resolve_domain(domain)
      domain || E2B.configuration&.domain || ENV["E2B_DOMAIN"] || Configuration::DEFAULT_DOMAIN
    end

    def build_http_client(api_key:, access_token:, domain:)
      config = E2B.configuration
      base_url = config&.api_url || ENV["E2B_API_URL"] || Configuration.default_api_url(domain)
      API::HttpClient.new(
        base_url: base_url,
        api_key: api_key,
        access_token: access_token,
        logger: config&.logger
      )
    end
  end
end
