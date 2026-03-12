# frozen_string_literal: true

module E2B
  module Services
    # Handle for watching directory changes in the sandbox
    #
    # Returned by {Filesystem#watch_dir}. Uses the polling-based watcher RPCs
    # (CreateWatcher/GetWatcherEvents/RemoveWatcher) from the filesystem proto service.
    #
    # The watcher is created externally and its ID is passed into this handle.
    # Call {#get_new_events} to poll for new filesystem changes, and {#stop}
    # to clean up the watcher when done.
    #
    # @example Basic usage
    #   handle = sandbox.files.watch_dir("/home/user/project")
    #   loop do
    #     events = handle.get_new_events
    #     events.each { |e| puts "#{e.name}: #{e.type}" }
    #     sleep 1
    #   end
    #   handle.stop
    #
    # @example With ensure block for cleanup
    #   handle = sandbox.files.watch_dir("/home/user/project")
    #   begin
    #     events = handle.get_new_events
    #     events.each { |e| process_event(e) }
    #   ensure
    #     handle.stop
    #   end
    class WatchHandle
      # @return [String] The watcher ID assigned by the CreateWatcher RPC
      attr_reader :watcher_id

      # Create a new WatchHandle
      #
      # @param watcher_id [String] The watcher ID returned by the CreateWatcher RPC
      # @param envd_rpc_proc [Proc] A callable that performs RPC calls. It must accept
      #   three positional arguments (service, method) and keyword arguments (body:, timeout:).
      #   Typically a lambda wrapping {BaseService#envd_rpc}.
      def initialize(watcher_id:, envd_rpc_proc:)
        @watcher_id = watcher_id
        @envd_rpc_proc = envd_rpc_proc
        @stopped = false
      end

      # Poll for new filesystem events since the last check
      #
      # Calls the GetWatcherEvents RPC to retrieve any filesystem events
      # that have occurred since the last poll (or since the watcher was created).
      #
      # @return [Array<Models::FilesystemEvent>] New events since last poll
      # @raise [E2B::E2BError] If the watcher has been stopped
      def get_new_events
        raise E2B::E2BError, "Watcher has been stopped" if @stopped

        response = @envd_rpc_proc.call(
          "filesystem.Filesystem", "GetWatcherEvents",
          body: { watcherId: @watcher_id }
        )

        events = extract_events(response)
        events.map { |e| Models::FilesystemEvent.from_hash(e) }
      end

      # Stop watching and clean up the watcher
      #
      # Calls the RemoveWatcher RPC to release server-side resources.
      # After calling this method, {#get_new_events} will raise an error.
      # Calling stop on an already-stopped handle is a no-op.
      #
      # @return [void]
      def stop
        return if @stopped

        @envd_rpc_proc.call(
          "filesystem.Filesystem", "RemoveWatcher",
          body: { watcherId: @watcher_id }
        )
        @stopped = true
      rescue StandardError
        @stopped = true
        # Ignore errors on cleanup - the watcher may have already been
        # removed server-side (e.g., sandbox shutdown)
      end

      # Check if the watcher has been stopped
      #
      # @return [Boolean] true if {#stop} has been called
      def stopped?
        @stopped
      end

      private

      # Extract events array from the RPC response
      #
      # The response may contain events under different keys depending on
      # the serialization format (camelCase JSON vs. symbol keys from parsed response).
      #
      # @param response [Hash] The parsed RPC response
      # @return [Array<Hash>] Array of raw event hashes
      def extract_events(response)
        return [] unless response.is_a?(Hash)

        response["events"] || response[:events] || []
      end
    end
  end
end
