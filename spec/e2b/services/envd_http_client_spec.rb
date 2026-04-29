# frozen_string_literal: true

require "spec_helper"

RSpec.describe E2B::Services::EnvdHttpClient do
  let(:client) do
    described_class.new(
      base_url: "https://49983-sbx_test.e2b.app",
      api_key: "test-key",
      sandbox_id: "sbx_test"
    )
  end

  describe "#parse_exit_code" do
    it "returns 0 for nil" do
      expect(client.send(:parse_exit_code, nil)).to eq(0)
    end

    it "passes Integers through" do
      expect(client.send(:parse_exit_code, 0)).to eq(0)
      expect(client.send(:parse_exit_code, 42)).to eq(42)
    end

    it "extracts integers from 'exit status N' strings" do
      expect(client.send(:parse_exit_code, "exit status 0")).to eq(0)
      expect(client.send(:parse_exit_code, "exit status 1")).to eq(1)
      expect(client.send(:parse_exit_code, "exit status 137")).to eq(137)
    end

    it "parses bare numeric strings" do
      expect(client.send(:parse_exit_code, "0")).to eq(0)
      expect(client.send(:parse_exit_code, "42")).to eq(42)
    end

    it "returns 1 for unrecognised non-zero status strings" do
      # Regression: previously str.include?("0") ? 0 : 1 would map any string
      # containing "0" to success — including "code: 100", "status: 20", etc.
      expect(client.send(:parse_exit_code, "code: 100")).to eq(1)
      expect(client.send(:parse_exit_code, "status: 20")).to eq(1)
      expect(client.send(:parse_exit_code, "killed")).to eq(1)
      expect(client.send(:parse_exit_code, "process exited with code 0")).to eq(1)
      expect(client.send(:parse_exit_code, "")).to eq(1)
    end
  end

  describe "#decode_base64" do
    it "decodes base64-encoded data" do
      encoded = Base64.strict_encode64("hello")
      expect(client.send(:decode_base64, encoded)).to eq("hello")
    end

    it "returns empty string for nil/empty input" do
      expect(client.send(:decode_base64, nil)).to eq("")
      expect(client.send(:decode_base64, "")).to eq("")
    end
  end

  describe "#create_connect_envelope" do
    it "produces a binary frame with flags=0, big-endian length, and the JSON body" do
      json = '{"hello":"world"}'
      envelope = client.send(:create_connect_envelope, json)

      expect(envelope.encoding).to eq(Encoding::ASCII_8BIT)
      expect(envelope.getbyte(0)).to eq(0)
      expect(envelope.byteslice(1, 4).unpack1("N")).to eq(json.bytesize)
      expect(envelope.byteslice(5, json.bytesize)).to eq(json.b)
    end

    it "handles UTF-8 multibyte payloads without raising Encoding::CompatibilityError" do
      utf8 = '{"msg":"héllo 日本語"}'
      expect { client.send(:create_connect_envelope, utf8) }.not_to raise_error

      envelope = client.send(:create_connect_envelope, utf8)
      expect(envelope.byteslice(1, 4).unpack1("N")).to eq(utf8.bytesize)
    end

    it "handles bodies large enough to put high bytes in the length prefix" do
      # A body of 0x10000 bytes encodes length as 0x00010000 (high byte = 0x00,
      # but middle byte is 0x01) — exercises ASCII-8BIT concat with non-trivial
      # length bytes.
      large = "a" * 65_536
      envelope = client.send(:create_connect_envelope, large)
      expect(envelope.byteslice(1, 4).unpack1("N")).to eq(65_536)
      expect(envelope.bytesize).to eq(5 + 65_536)
    end
  end

  describe "#parse_connect_stream" do
    it "parses a multi-frame binary Connect envelope" do
      msg1 = '{"a":1}'
      msg2 = '{"b":2}'

      body = "".b
      body << "\x00".b << [msg1.bytesize].pack("N") << msg1.b
      body << "\x00".b << [msg2.bytesize].pack("N") << msg2.b

      messages = client.send(:parse_connect_stream, body)
      expect(messages).to eq([msg1, msg2])
    end

    it "falls back to NDJSON when the body does not start with 0x00" do
      body = "{\"a\":1}\n{\"b\":2}\n"
      messages = client.send(:parse_connect_stream, body)
      expect(messages).to eq(['{"a":1}', '{"b":2}'])
    end

    it "treats a single JSON object body as one message" do
      body = '{"only":"one"}'
      messages = client.send(:parse_connect_stream, body)
      expect(messages).to eq([body])
    end
  end
end
