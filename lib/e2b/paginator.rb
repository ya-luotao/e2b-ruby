# frozen_string_literal: true

require "uri"

module E2B
  class BasePaginator
    attr_reader :next_token

    def initialize(limit:, next_token: nil, &fetch_page)
      @limit = limit
      @next_token = next_token
      @fetch_page = fetch_page
      @has_next = true
    end

    def has_next?
      @has_next
    end

    def next_items
      raise E2BError, "No more items to fetch" unless has_next?

      items, token = @fetch_page.call(limit: @limit, next_token: @next_token)
      @next_token = token
      @has_next = !@next_token.nil? && !@next_token.empty?
      items
    end
  end

  class SandboxPaginator < BasePaginator
    def initialize(http_client:, query: nil, limit: 100, next_token: nil)
      normalized_query = normalize_query(query)

      super(limit: limit, next_token: next_token) do |limit:, next_token:|
        params = { limit: limit }
        params[:nextToken] = next_token if next_token
        if normalized_query[:metadata]
          params[:metadata] = self.class.encode_metadata(normalized_query[:metadata])
        end
        params[:state] = normalized_query[:state] if normalized_query[:state]

        response = http_client.get("/v2/sandboxes", params: params, detailed: true)
        sandboxes = extract_sandboxes(response.body)

        [
          Array(sandboxes).map { |sandbox_data| Models::SandboxInfo.from_hash(sandbox_data) },
          response.headers["x-next-token"]
        ]
      end
    end

    def self.encode_metadata(metadata)
      encoded_pairs = metadata.to_h.each_with_object({}) do |(key, value), result|
        result[URI.encode_www_form_component(key.to_s)] = URI.encode_www_form_component(value.to_s)
      end

      URI.encode_www_form(encoded_pairs)
    end

    private

    def normalize_query(query)
      return {} unless query

      state = query[:state] || query["state"]
      {
        metadata: query[:metadata] || query["metadata"],
        state: state ? Array(state).map(&:to_s) : nil
      }
    end

    def extract_sandboxes(body)
      return body if body.is_a?(Array)
      return body["sandboxes"] || body[:sandboxes] || [] if body.is_a?(Hash)

      []
    end
  end

  class SnapshotPaginator < BasePaginator
    def initialize(http_client:, sandbox_id: nil, limit: 100, next_token: nil)
      super(limit: limit, next_token: next_token) do |limit:, next_token:|
        params = { limit: limit }
        params[:sandboxID] = sandbox_id if sandbox_id
        params[:nextToken] = next_token if next_token

        response = http_client.get("/snapshots", params: params, detailed: true)
        snapshots = response.body.is_a?(Array) ? response.body : []

        [
          snapshots.map { |snapshot_data| Models::SnapshotInfo.from_hash(snapshot_data) },
          response.headers["x-next-token"]
        ]
      end
    end
  end
end
