# frozen_string_literal: true

require "uri"

module E2B
  class Template
    class << self
      def exists(name, api_key: nil, access_token: nil, domain: nil)
        alias_exists(name, api_key: api_key, access_token: access_token, domain: domain)
      end

      def alias_exists(alias_name, api_key: nil, access_token: nil, domain: nil)
        credentials = resolve_credentials(api_key: api_key, access_token: access_token)
        http_client = build_http_client(**credentials, domain: resolve_domain(domain))
        http_client.get("/templates/aliases/#{escape_path_segment(alias_name)}")
        true
      rescue E2B::NotFoundError
        false
      rescue E2B::AuthenticationError => e
        return true if e.status_code == 403

        raise
      end

      def assign_tags(target_name, tags, api_key: nil, access_token: nil, domain: nil)
        credentials = resolve_credentials(api_key: api_key, access_token: access_token)
        http_client = build_http_client(**credentials, domain: resolve_domain(domain))
        response = http_client.post("/templates/tags", body: {
          target: target_name,
          tags: normalize_tags(tags)
        })

        Models::TemplateTagInfo.from_hash(response)
      end

      def remove_tags(name, tags, api_key: nil, access_token: nil, domain: nil)
        credentials = resolve_credentials(api_key: api_key, access_token: access_token)
        http_client = build_http_client(**credentials, domain: resolve_domain(domain))
        http_client.delete("/templates/tags", body: {
          name: name,
          tags: normalize_tags(tags)
        })
        nil
      end

      def get_tags(template_id, api_key: nil, access_token: nil, domain: nil)
        credentials = resolve_credentials(api_key: api_key, access_token: access_token)
        http_client = build_http_client(**credentials, domain: resolve_domain(domain))
        response = http_client.get("/templates/#{escape_path_segment(template_id)}/tags")

        Array(response).map { |item| Models::TemplateTag.from_hash(item) }
      end

      def get_build_status(build_info = nil, logs_offset: nil, api_key: nil, access_token: nil, domain: nil,
                           template_id: nil, build_id: nil)
        resolved_template_id, resolved_build_id = extract_build_identifiers(
          build_info,
          template_id: template_id,
          build_id: build_id
        )

        credentials = resolve_credentials(api_key: api_key, access_token: access_token)
        http_client = build_http_client(**credentials, domain: resolve_domain(domain))
        params = {}
        params[:logsOffset] = logs_offset unless logs_offset.nil?

        response = http_client.get(
          "/templates/#{escape_path_segment(resolved_template_id)}/builds/#{escape_path_segment(resolved_build_id)}/status",
          params: params
        )

        Models::TemplateBuildStatusResponse.from_hash(response)
      end

      def wait_for_build_finish(build_info = nil, logs_offset: 0, on_build_logs: nil, logs_refresh_frequency: 0.2,
                                api_key: nil, access_token: nil, domain: nil, template_id: nil, build_id: nil)
        current_logs_offset = logs_offset

        loop do
          status = get_build_status(
            build_info,
            logs_offset: current_logs_offset,
            api_key: api_key,
            access_token: access_token,
            domain: domain,
            template_id: template_id,
            build_id: build_id
          )

          current_logs_offset += status.log_entries.length
          status.log_entries.each { |entry| on_build_logs.call(entry) } if on_build_logs

          case status.status
          when "building", "waiting"
            sleep_for_build_poll(logs_refresh_frequency)
          when "ready"
            return status
          when "error"
            raise BuildError, status.reason&.message || "Unknown build error occurred."
          else
            raise BuildError, "Unknown build status: #{status.status}"
          end
        end
      end

      private

      def normalize_tags(tags)
        Array(tags).flatten.compact
      end

      def extract_build_identifiers(build_info, template_id:, build_id:)
        if build_info
          if build_info.respond_to?(:template_id) && build_info.respond_to?(:build_id)
            return [build_info.template_id, build_info.build_id]
          end

          if build_info.is_a?(Hash)
            resolved_template_id = build_info[:template_id] || build_info["template_id"] ||
              build_info[:templateID] || build_info["templateID"]
            resolved_build_id = build_info[:build_id] || build_info["build_id"] ||
              build_info[:buildID] || build_info["buildID"]

            return [resolved_template_id, resolved_build_id]
          end
        end

        return [template_id, build_id] if template_id && build_id

        raise ArgumentError, "Provide build_info or both template_id: and build_id:"
      end

      def escape_path_segment(value)
        URI.encode_www_form_component(value.to_s)
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

      def sleep_for_build_poll(interval)
        sleep(interval)
      end
    end
  end
end
