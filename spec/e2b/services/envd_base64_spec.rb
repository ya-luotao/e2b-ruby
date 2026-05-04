# frozen_string_literal: true

require "spec_helper"

RSpec.describe E2B::Services::EnvdBase64 do
  describe ".decode_process_output" do
    it "decodes base64-encoded data as valid UTF-8" do
      encoded = Base64.strict_encode64("hello")
      expect(described_class.decode_process_output(encoded)).to eq("hello")
    end

    it "returns empty string for nil/empty input" do
      expect(described_class.decode_process_output(nil)).to eq("")
      expect(described_class.decode_process_output("")).to eq("")
    end

    it "scrubs bytes that are not valid UTF-8" do
      invalid_utf8 = "\xC3\x28".b
      encoded = Base64.strict_encode64(invalid_utf8)
      decoded = described_class.decode_process_output(encoded)

      expect(decoded.encoding).to eq(Encoding::UTF_8)
      expect(decoded.valid_encoding?).to be true
    end
  end
end
