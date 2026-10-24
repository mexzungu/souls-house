require "test_helper"
require "open3"
require "socket"
require "tempfile"

class SoulshouseCommsTest < ActiveSupport::TestCase

  SCRIPT = Rails.root.join("agent-runtime/soulshouse-comms")

  test "messages calls the manifest's endpoint with the resident key and prints JSON" do
    request = nil
    stdout = stderr = status = nil
    request = capture_request('{"chat":{"id":"chat_1"},"messages":[{"provider_message_id":"m1","body":"hi"}]}') do |base|
      with_manifest(base) do |manifest|
        stdout, stderr, status = Open3.capture3(
          { "SOULSHOUSE_BEARER_TOKEN" => "hx_test", "SOULSHOUSE_SERVICES_FILE" => manifest },
          "python3", SCRIPT.to_s, "messages", "--chat", "447700900123@s.whatsapp.net", "--since", "2026-10-09T10:00:00Z", "--limit", "5"
        )
      end
    end

    assert status.success?, stderr
    assert_equal "m1", JSON.parse(stdout).dig("messages", 0, "provider_message_id")
    assert_equal "Bearer hx_test", request[:headers]["authorization"]
    path, query = request[:request_line].split[1].split("?", 2)
    assert_equal "/api/v1/service_connections/svc_123/comms/messages", path
    assert_equal({ "chat" => [ "447700900123@s.whatsapp.net" ], "since" => [ "2026-10-09T10:00:00Z" ], "limit" => [ "5" ] }, CGI.parse(query))
  end

  test "chats needs a choice when several comms connections are present" do
    manifest = Tempfile.new([ "services", ".yml" ])
    manifest.write({ "services" => [
      { "connection_id" => "svc_1", "provider" => "whatsapp" },
      { "connection_id" => "svc_2", "provider" => "whatsapp" }
    ] }.to_yaml)
    manifest.close

    _stdout, stderr, status = Open3.capture3(
      { "HELIXKIT_BEARER_TOKEN" => "hx_test", "HELIXKIT_SERVICES_FILE" => manifest.path },
      "python3", SCRIPT.to_s, "chats"
    )

    assert_not status.success?
    assert_includes stderr, "--connection"
  ensure
    manifest&.unlink
  end

  test "search calls a Telegram connection's search endpoint with the query, chat, limit and scope" do
    stdout = stderr = status = nil
    request = capture_request('{"scope":"synced","results":[{"provider_message_id":"9","body":"lunch?"}]}') do |base|
      with_manifest(base, provider: "telegram") do |manifest|
        stdout, stderr, status = Open3.capture3(
          { "SOULSHOUSE_BEARER_TOKEN" => "hx_test", "SOULSHOUSE_SERVICES_FILE" => manifest },
          "python3", SCRIPT.to_s, "search", "--query", "lunch friday", "--chat", "user:1", "--limit", "5", "--scope", "synced"
        )
      end
    end

    assert status.success?, stderr
    assert_equal "lunch?", JSON.parse(stdout).dig("results", 0, "body")
    path, query = request[:request_line].split[1].split("?", 2)
    assert_equal "/api/v1/service_connections/svc_123/comms/search", path
    assert_equal({ "query" => [ "lunch friday" ], "chat" => [ "user:1" ], "limit" => [ "5" ], "scope" => [ "synced" ] }, CGI.parse(query))
  end

  test "search on a WhatsApp connection says it has none" do
    _stdout, stderr, status = with_manifest("http://127.0.0.1:9") do |manifest|
      Open3.capture3(
        { "SOULSHOUSE_BEARER_TOKEN" => "hx_test", "SOULSHOUSE_SERVICES_FILE" => manifest },
        "python3", SCRIPT.to_s, "search", "--query", "x"
      )
    end

    assert_not status.success?
    assert_includes stderr, "no search"
  end

  test "send posts stdin text, the chat and the request id to the send endpoint, and prints the record" do
    stdout = stderr = status = nil
    request = capture_post('{"send":{"id":"send_1","status":"sent","client_request_id":"lunch-1"}}') do |base|
      with_manifest(base, send: true) do |manifest|
        stdout, stderr, status = Open3.capture3(
          { "SOULSHOUSE_BEARER_TOKEN" => "hx_test", "SOULSHOUSE_SERVICES_FILE" => manifest },
          "python3", SCRIPT.to_s, "send", "--chat", "447700900123@s.whatsapp.net", "--text", "-", "--request-id", "lunch-1",
          stdin_data: "On my way ✨\n"
        )
      end
    end

    assert status.success?, stderr
    assert_equal "sent", JSON.parse(stdout).dig("send", "status")
    assert_equal "POST /api/v1/service_connections/svc_123/comms/messages HTTP/1.1", request[:request_line]
    assert_equal "Bearer hx_test", request[:headers]["authorization"]
    assert_equal({ "chat" => "447700900123@s.whatsapp.net", "text" => "On my way ✨", "client_request_id" => "lunch-1" },
                 JSON.parse(request[:body]))
  end

  test "send without a request id makes one, prints it for a retry, and keeps unknown unknown" do
    stdout = stderr = status = nil
    request = capture_post('{"send":{"id":"send_2","status":"unknown","error_code":"connector_timeout"}}') do |base|
      with_manifest(base, send: true) do |manifest|
        stdout, stderr, status = Open3.capture3(
          { "SOULSHOUSE_BEARER_TOKEN" => "hx_test", "SOULSHOUSE_SERVICES_FILE" => manifest },
          "python3", SCRIPT.to_s, "send", "--chat", "chat_7", "--text", "-", stdin_data: "hello"
        )
      end
    end

    assert_equal 3, status.exitstatus, stderr
    assert_equal "unknown", JSON.parse(stdout).dig("send", "status")
    sent_id = JSON.parse(request[:body])["client_request_id"]
    assert_match(/\Acli-[0-9a-f]{32}\z/, sent_id)
    assert_includes stderr, "request_id: #{sent_id}"
  end

  test "a failed send exits 2 with the record printed" do
    stdout = status = nil
    capture_post('{"send":{"id":"send_3","status":"failed","error_code":"refused_at_dispatch_rate_limited"}}') do |base|
      with_manifest(base, send: true) do |manifest|
        stdout, _stderr, status = Open3.capture3(
          { "SOULSHOUSE_BEARER_TOKEN" => "hx_test", "SOULSHOUSE_SERVICES_FILE" => manifest },
          "python3", SCRIPT.to_s, "send", "--chat", "chat_7", "--text", "-", "--request-id", "r1", stdin_data: "hello"
        )
      end
    end
    assert_equal 2, status.exitstatus
    assert_equal "refused_at_dispatch_rate_limited", JSON.parse(stdout).dig("send", "error_code")
  end

  test "send without a send endpoint in the manifest says so and makes no request" do
    _stdout, stderr, status = with_manifest("http://127.0.0.1:9") do |manifest|
      Open3.capture3(
        { "SOULSHOUSE_BEARER_TOKEN" => "hx_test", "SOULSHOUSE_SERVICES_FILE" => manifest },
        "python3", SCRIPT.to_s, "send", "--chat", "chat_7", "--text", "-", stdin_data: "hello"
      )
    end
    assert_equal 66, status.exitstatus
    assert_includes stderr, "does not let you send"
  end

  test "send refuses an empty message" do
    _stdout, stderr, status = Open3.capture3(
      { "SOULSHOUSE_BEARER_TOKEN" => "hx_test" }, "python3", SCRIPT.to_s, "send", "--chat", "x", "--text", "-", stdin_data: "  \n"
    )
    assert_equal 64, status.exitstatus
    assert_includes stderr, "empty"
  end

  test "send refuses to follow a redirect with the resident key" do
    [ 302, 307, 308 ].each do |code|
      stdout = stderr = status = nil
      requests = capture_redirects(code) do |base|
        with_manifest(base, send: true) do |manifest|
          stdout, stderr, status = Open3.capture3(
            { "SOULSHOUSE_BEARER_TOKEN" => "hx_secret_key", "SOULSHOUSE_SERVICES_FILE" => manifest },
            "python3", SCRIPT.to_s, "send", "--chat", "chat_7", "--text", "-", "--request-id", "r1", stdin_data: "hello"
          )
        end
      end
      assert_not status.success?, code
      assert_equal 1, requests.size, "only the first request was made (#{code})"
      assert_match "refused to follow a redirect (#{code})", stdout + stderr
      assert_not_includes stdout + stderr, "hx_secret_key"
    end
  end

  private

  def with_manifest(base, provider: "whatsapp", send: false)
    credentials = {
      "chats_endpoint" => "#{base}/api/v1/service_connections/svc_123/comms/chats",
      "messages_endpoint" => "#{base}/api/v1/service_connections/svc_123/comms/messages"
    }
    credentials["send_endpoint"] = credentials["messages_endpoint"] if send
    credentials["search_endpoint"] = "#{base}/api/v1/service_connections/svc_123/comms/search" if provider == "telegram"
    manifest = Tempfile.new([ "services", ".yml" ])
    manifest.write({ "services" => [ {
      "connection_id" => "svc_123", "provider" => provider, "credentials" => credentials
    } ] }.to_yaml)
    manifest.close
    yield manifest.path
  ensure
    manifest&.unlink
  end

  def capture_request(payload)
    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]
    captured = Queue.new
    thread = Thread.new do
      socket = server.accept
      request_line = socket.gets&.strip
      headers = {}
      while (line = socket.gets)
        line = line.strip
        break if line.empty?
        name, value = line.split(":", 2)
        headers[name.downcase] = value.to_s.strip
      end
      captured << { request_line: request_line, headers: headers }
      socket.write("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: #{payload.bytesize}\r\nConnection: close\r\n\r\n#{payload}")
      socket.close
    ensure
      server.close
    end

    yield "http://127.0.0.1:#{port}"
    captured.pop
  ensure
    thread&.join(2)
    server&.close unless server&.closed?
  end

  # Serves on a local port while the block runs: each request is recorded
  # (with its body) and answered by `respond`. Returns the requests.
  def serve(respond)
    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]
    captured = Queue.new
    thread = Thread.new do
      loop do
        socket = server.accept
        request_line = socket.gets&.strip
        headers = {}
        while (line = socket.gets)
          line = line.strip
          break if line.empty?
          name, value = line.split(":", 2)
          headers[name.downcase] = value.to_s.strip
        end
        body = socket.read(headers["content-length"].to_i).to_s.force_encoding(Encoding::UTF_8)
        captured << { request_line: request_line, headers: headers, body: body }
        socket.write(respond.call(port))
        socket.close
      end
    rescue IOError, Errno::EBADF
      nil
    end

    yield "http://127.0.0.1:#{port}"
    requests = []
    requests << captured.pop until captured.empty?
    requests
  ensure
    server&.close unless server&.closed?
    thread&.join(2)
  end

  def capture_post(payload, &block)
    serve(->(_port) { "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: #{payload.bytesize}\r\nConnection: close\r\n\r\n#{payload}" }, &block).sole
  end

  def capture_redirects(code, &block)
    serve(->(port) { "HTTP/1.1 #{code} Moved\r\nLocation: http://127.0.0.1:#{port}/elsewhere\r\nContent-Length: 0\r\nConnection: close\r\n\r\n" }, &block)
  end

end
