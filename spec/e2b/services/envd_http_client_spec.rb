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

  def rpc_response(status:, body:, headers: {})
    described_class::RpcResponse.new(status: status, body: body, headers: headers)
  end

  describe "RpcResponse#success?" do
    it "is true for 2xx and false otherwise" do
      expect(rpc_response(status: 204, body: nil).success?).to be(true)
      expect(rpc_response(status: 500, body: nil).success?).to be(false)
    end
  end

  describe "#handle_error mapping" do
    it "maps status codes to the matching error classes" do
      {
        401 => E2B::AuthenticationError,
        403 => E2B::AuthenticationError,
        404 => E2B::NotFoundError,
        429 => E2B::RateLimitError,
        500 => E2B::E2BError
      }.each do |status, klass|
        expect { client.send(:handle_error, rpc_response(status: status, body: {})) }
          .to raise_error(klass) { |error| expect(error.status_code).to eq(status) }
      end
    end

    it "extracts the message from a JSON body and carries headers" do
      resp = rpc_response(status: 404, body: { "message" => "missing sandbox" }, headers: { "x" => "y" })
      expect { client.send(:handle_error, resp) }
        .to raise_error(E2B::NotFoundError, "missing sandbox") { |error| expect(error.headers).to eq("x" => "y") }
    end
  end

  describe "#extract_error_message" do
    it "prefers message, then error, then a string body, then a generic fallback" do
      expect(client.send(:extract_error_message, rpc_response(status: 400, body: { "message" => "m" }))).to eq("m")
      expect(client.send(:extract_error_message, rpc_response(status: 400, body: { "error" => "e" }))).to eq("e")
      expect(client.send(:extract_error_message, rpc_response(status: 400, body: "raw"))).to eq("raw")
      expect(client.send(:extract_error_message, rpc_response(status: 400, body: nil))).to eq("HTTP 400 error")
    end
  end

  # Frame one or more JSON strings into a binary Connect envelope stream, the
  # wire format handle_rpc_response decodes.
  def connect_stream(*messages)
    body = "".b
    messages.each { |m| body << "\x00".b << [m.bytesize].pack("N") << m.b }
    body
  end

  describe "#handle_rpc_response" do
    it "decodes Data events, parses the End exit code, and collects every event" do
      body = connect_stream(
        %({"event":{"Data":{"stdout":"#{Base64.strict_encode64("out")}","stderr":"#{Base64.strict_encode64("err")}"}}}),
        %({"event":{"End":{"exitCode":0}}})
      )

      result = client.send(:handle_rpc_response, "process.Process", "Start") do
        rpc_response(status: 200, body: body)
      end

      expect(result[:stdout]).to eq("out")
      expect(result[:stderr]).to eq("err")
      expect(result[:exit_code]).to eq(0)
      expect(result[:events].size).to eq(2)
    end

    it "unwraps a result envelope and reads top-level stdout and a string exit code" do
      body = connect_stream(
        %({"result":{"stdout":"#{Base64.strict_encode64("hi")}","exitCode":"exit status 3"}})
      )

      result = client.send(:handle_rpc_response, "s", "m") { rpc_response(status: 200, body: body) }

      expect(result[:stdout]).to eq("hi")
      expect(result[:exit_code]).to eq(3)
    end

    it "decodes multibyte UTF-8 process output without raising" do
      body = connect_stream(
        %({"event":{"Data":{"stdout":"#{Base64.strict_encode64("héllo 日本語")}"}}})
      )

      result = client.send(:handle_rpc_response, "s", "m") { rpc_response(status: 200, body: body) }

      expect(result[:stdout]).to eq("héllo 日本語")
    end

    it "skips unparseable frames instead of raising" do
      body = connect_stream("{not json", %({"event":{"End":{"exitCode":0}}}))

      result = client.send(:handle_rpc_response, "s", "m") { rpc_response(status: 200, body: body) }

      expect(result[:exit_code]).to eq(0)
      expect(result[:events].size).to eq(1)
    end

    it "returns an empty hash for an empty body" do
      result = client.send(:handle_rpc_response, "s", "m") { rpc_response(status: 200, body: "") }
      expect(result).to eq({})
    end

    it "raises a mapped error for a non-success response" do
      expect do
        client.send(:handle_rpc_response, "s", "m") { rpc_response(status: 404, body: { "message" => "nope" }) }
      end.to raise_error(E2B::NotFoundError, "nope")
    end
  end

  describe "#with_retry" do
    it "returns the block result on success" do
      expect(client.send(:with_retry, "op") { 42 }).to eq(42)
    end

    it "retries transient network errors, then succeeds" do
      allow(client).to receive(:sleep) # avoid real 2**n backoff waits
      attempts = 0

      result = client.send(:with_retry, "op") do
        attempts += 1
        raise Errno::ECONNRESET if attempts < 3

        "ok"
      end

      expect(result).to eq("ok")
      expect(attempts).to eq(3)
    end

    it "raises after exhausting retries" do
      allow(client).to receive(:sleep)

      expect do
        client.send(:with_retry, "op", max_retries: 2) { raise Net::ReadTimeout }
      end.to raise_error(E2B::E2BError, /failed after 2 retries/)
    end

    it "does not retry when abort_if is true (observable side effects already happened)" do
      calls = 0

      expect do
        client.send(:with_retry, "op", abort_if: -> { true }) do
          calls += 1
          raise Errno::ECONNRESET
        end
      end.to raise_error(E2B::E2BError, /failed after partial response/)

      expect(calls).to eq(1)
    end

    it "does not retry when max_retries is 0 (non-idempotent /Start)" do
      expect do
        client.send(:with_retry, "op", max_retries: 0) { raise EOFError }
      end.to raise_error(E2B::E2BError, /failed after 0 retries/)
    end

    it "propagates errors it does not classify as transient" do
      expect { client.send(:with_retry, "op") { raise ArgumentError, "boom" } }
        .to raise_error(ArgumentError, "boom")
    end
  end

  describe "#resolve_proxy" do
    around do |example|
      keys = %w[no_proxy NO_PROXY http_proxy HTTP_PROXY https_proxy HTTPS_PROXY]
      saved = ENV.to_hash.slice(*keys)
      keys.each { |k| ENV.delete(k) }
      begin
        example.run
      ensure
        keys.each { |k| ENV.delete(k) }
        saved.each { |k, v| ENV[k] = v }
      end
    end

    let(:https_url) { URI.parse("https://49983-sbx.e2b.app/path") }

    it "returns nil when no proxy is configured" do
      expect(client.send(:resolve_proxy, https_url)).to be_nil
    end

    it "returns the https proxy URI for an https URL" do
      ENV["https_proxy"] = "http://proxy.local:3128"
      proxy = client.send(:resolve_proxy, https_url)
      expect(proxy.host).to eq("proxy.local")
      expect(proxy.port).to eq(3128)
    end

    it "bypasses the proxy when the host suffix matches no_proxy" do
      ENV["https_proxy"] = "http://proxy.local:3128"
      ENV["no_proxy"] = "e2b.app"
      expect(client.send(:resolve_proxy, https_url)).to be_nil
    end

    it "bypasses the proxy for a wildcard no_proxy" do
      ENV["https_proxy"] = "http://proxy.local:3128"
      ENV["no_proxy"] = "*"
      expect(client.send(:resolve_proxy, https_url)).to be_nil
    end

    it "returns nil for an unparseable proxy URL" do
      client # build the Faraday connection before poisoning the proxy env var
      ENV["https_proxy"] = "http://["
      expect(client.send(:resolve_proxy, https_url)).to be_nil
    end
  end

  describe "#normalize_path" do
    it "strips leading slashes so paths join cleanly onto the base URL" do
      expect(client.send(:normalize_path, "/files")).to eq("files")
      expect(client.send(:normalize_path, "///a/b")).to eq("a/b")
      expect(client.send(:normalize_path, "files")).to eq("files")
    end
  end

  describe "#apply_custom_headers" do
    it "sets each header on the request and is a no-op for nil" do
      request = Net::HTTP::Post.new("/")
      client.send(:apply_custom_headers, request, { "X-Foo" => "bar" })
      expect(request["X-Foo"]).to eq("bar")

      expect { client.send(:apply_custom_headers, request, nil) }.not_to raise_error
    end
  end

  describe "#handle_response" do
    # A minimal stand-in for the Faraday::Response that handle_response inspects.
    def faraday_like(success:, body:, headers: {}, status: 200)
      resp = Object.new
      resp.define_singleton_method(:success?) { success }
      resp.define_singleton_method(:body) { body }
      resp.define_singleton_method(:headers) { headers }
      resp.define_singleton_method(:status) { status }
      resp
    end

    it "parses a JSON string body" do
      resp = faraday_like(success: true, body: '{"ok":true}', headers: { "content-type" => "application/json" })
      expect(client.send(:handle_response) { resp }).to eq("ok" => true)
    end

    it "returns a non-JSON string body unchanged" do
      resp = faraday_like(success: true, body: "plain text", headers: { "content-type" => "text/plain" })
      expect(client.send(:handle_response) { resp }).to eq("plain text")
    end

    it "returns an already-parsed Hash body as-is" do
      resp = faraday_like(success: true, body: { "x" => 1 })
      expect(client.send(:handle_response) { resp }).to eq("x" => 1)
    end

    it "raises a mapped error for an unsuccessful response" do
      resp = faraday_like(success: false, body: { "message" => "bad" }, status: 500)
      expect { client.send(:handle_response) { resp } }.to raise_error(E2B::E2BError, "bad")
    end

    it "maps Faraday::TimeoutError to E2B::TimeoutError" do
      expect { client.send(:handle_response) { raise Faraday::TimeoutError } }
        .to raise_error(E2B::TimeoutError)
    end

    it "maps Faraday::ConnectionFailed to E2B::E2BError" do
      expect { client.send(:handle_response) { raise Faraday::ConnectionFailed, "nope" } }
        .to raise_error(E2B::E2BError, /Connection to sandbox failed/)
    end
  end
end
