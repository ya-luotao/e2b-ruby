# frozen_string_literal: true

module E2B
  module Models
    # Information about a sandbox
    class SandboxInfo
      # @return [String] Sandbox ID
      attr_reader :sandbox_id

      # @return [String] Template ID used to create the sandbox
      attr_reader :template_id

      # @return [String, nil] Alias/name of the sandbox
      attr_reader :alias_name

      # @return [String] Client ID
      attr_reader :client_id

      # @return [Time] When the sandbox was started
      attr_reader :started_at

      # @return [Time] When the sandbox will end (timeout)
      attr_reader :end_at

      # @return [Integer] CPU count
      attr_reader :cpu_count

      # @return [Integer] Memory in MB
      attr_reader :memory_mb

      # @return [Hash] Metadata
      attr_reader :metadata

      # Create from API response hash
      #
      # @param data [Hash] API response data
      # @return [SandboxInfo]
      def self.from_hash(data)
        new(
          sandbox_id: data["sandboxID"] || data["sandbox_id"] || data[:sandboxID],
          template_id: data["templateID"] || data["template_id"] || data[:templateID],
          alias_name: data["alias"] || data[:alias],
          client_id: data["clientID"] || data["client_id"] || data[:clientID],
          started_at: parse_time(data["startedAt"] || data["started_at"] || data[:startedAt]),
          end_at: parse_time(data["endAt"] || data["end_at"] || data[:endAt]),
          cpu_count: data["cpuCount"] || data["cpu_count"] || data[:cpuCount],
          memory_mb: data["memoryMB"] || data["memory_mb"] || data[:memoryMB],
          metadata: data["metadata"] || data[:metadata] || {}
        )
      end

      def initialize(sandbox_id:, template_id:, alias_name: nil, client_id: nil,
                     started_at: nil, end_at: nil, cpu_count: nil, memory_mb: nil, metadata: {})
        @sandbox_id = sandbox_id
        @template_id = template_id
        @alias_name = alias_name
        @client_id = client_id
        @started_at = started_at
        @end_at = end_at
        @cpu_count = cpu_count
        @memory_mb = memory_mb
        @metadata = metadata || {}
      end

      # Check if sandbox is still running (not past end_at)
      #
      # @return [Boolean]
      def running?
        return true if @end_at.nil?

        Time.now < @end_at
      end

      # Time remaining until timeout
      #
      # @return [Integer] Seconds remaining, 0 if expired
      def time_remaining
        return 0 if @end_at.nil?

        remaining = (@end_at - Time.now).to_i
        remaining.positive? ? remaining : 0
      end

      def self.parse_time(value)
        return nil if value.nil?
        return value if value.is_a?(Time)

        Time.parse(value)
      rescue ArgumentError
        nil
      end
    end
  end
end
