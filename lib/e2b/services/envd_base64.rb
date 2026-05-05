# frozen_string_literal: true

require "base64"

module E2B
  module Services
    # Base64 payloads from envd wrap raw subprocess / PTY bytes.
    module EnvdBase64
      module_function

      # @param data [String, nil] base64-encoded chunk from envd
      # @return [String] UTF-8 string with invalid byte sequences scrubbed; "" if +data+ is nil or empty
      def decode_process_output(data)
        return "" if data.nil? || data.empty?

        Base64.decode64(data).force_encoding(Encoding::UTF_8).scrub
      rescue StandardError
        data.to_s
      end
    end
  end
end
