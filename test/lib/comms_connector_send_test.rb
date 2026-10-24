require "test_helper"
require "support/comms_send_helpers"
require "support/whatsapp_comms_helpers"

# CommsConnector.send_text against the Rails → WhatsApp connector wire
# contract (WhatsApp proposal, "Sending"): what the signed command carries,
# and how every answer maps to a send status. Only an explicit answer is
# sent or failed; everything else is unknown.
class CommsConnectorSendTest < ActiveSupport::TestCase

  include CommsSendHelpers
  include WhatsappCommsHelpers

  setup do
    setup_comms_send
    grant_send!
    @send, = CommsSending.claim!(connection: @connection, agent: @agent, chat: @chat, text: "On my way ✨", client_request_id: "wire")
  end

  teardown { teardown_comms_send }

  test "the command is signed with the command key and carries attempt, send id, message id, chat and text" do
    outcome, request = answer(200, { status: "sent", message_id: @send.provider_message_id, sent_at: "2026-10-24T10:00:01Z" })

    assert_equal "sent", outcome.status
    assert_equal "/connections/#{@connection.public_id}/send_text", request.path
    body = JSON.parse(request.body)
    assert_equal({ "attempt" => @connection.pairing_attempt, "send_id" => @send.public_id, "message_id" => @send.provider_message_id,
                   "chat" => "447700900123@s.whatsapp.net", "text" => "On my way ✨",
                   "connection" => @connection.public_id, "operation" => "send_text" },
                 body.except("command_id", "issued_at"))
    assert_kind_of Integer, body["attempt"]
    expected = CommsCommandSignature.sign(secret: "test-command-key", key_id: request["X-Comms-Key-Id"], connection_id: @connection.public_id,
                                          operation: "send_text", command_id: body["command_id"], issued_at: body["issued_at"], body: request.body)
    assert_equal expected, request["X-Comms-Command-Signature"]
    assert_match(/\A[A-Za-z0-9_-]{1,64}\z/, body["send_id"])
  end

  test "200 sent records the provider message id and WhatsApp's time" do
    outcome, = answer(200, { status: "sent", message_id: @send.provider_message_id, sent_at: "2026-10-24T10:00:01Z" })
    assert_equal [ "sent", @send.provider_message_id, Time.utc(2026, 10, 24, 10, 0, 1), nil ],
                 [ outcome.status, outcome.provider_message_id, outcome.sent_at, outcome.error_code ]
  end

  test "explicit refusals are failed with the connector's code (and reason)" do
    {
      [ 409, "not_connected" ] => nil, [ 409, "stale_attempt" ] => nil,
      [ 422, "bad_message_id" ] => nil, [ 422, "bad_chat" ] => nil, [ 422, "unsupported_chat" ] => nil,
      [ 422, "bad_text" ] => nil, [ 422, "send_mismatch" ] => nil, [ 422, "refused" ] => "not_on_whatsapp",
      [ 422, "bad_send_id" ] => nil, [ 422, "not_on_whatsapp" ] => nil, [ 422, "recipient_lookup_failed" ] => nil,
      [ 422, "group_lookup_failed" ] => nil
    }.each do |(status, error), reason|
      outcome, = answer(status, { error: error, reason: reason }.compact)
      assert_equal [ "failed", error, reason ], [ outcome.status, outcome.error_code, outcome.error_reason ], error
    end
  end

  test "outcome_unknown, timeouts, 5xx, unparseable and unrecognised answers stay unknown" do
    assert_equal %w[unknown outcome_unknown], answer(409, { error: "outcome_unknown" }).first.to_h.values_at(:status, :error_code)
    assert_equal %w[unknown connector_http_500], answer(500, { error: "boom" }).first.to_h.values_at(:status, :error_code)
    assert_equal %w[unknown connector_http_502], answer(502, "<html>bad gateway</html>").first.to_h.values_at(:status, :error_code)
    assert_equal %w[unknown connector_unrecognised], answer(200, "not json").first.to_h.values_at(:status, :error_code)
    assert_equal %w[unknown connector_unrecognised], answer(200, { status: "queued" }).first.to_h.values_at(:status, :error_code)
    assert_equal %w[unknown connector_unrecognised], answer(200, { status: "sent" }).first.to_h.values_at(:status, :error_code)
    assert_equal %w[unknown connector_http_409], answer(409, { error: "something_new" }).first.to_h.values_at(:status, :error_code)
    assert_equal %w[unknown connector_http_422], answer(422, { error: "something_new" }).first.to_h.values_at(:status, :error_code)
    assert_equal %w[unknown connector_http_500], answer(500, { error: "send_failed" }).first.to_h.values_at(:status, :error_code)
    assert_equal %w[unknown connector_http_502], answer(502, { error: "send_unknown" }).first.to_h.values_at(:status, :error_code)

    with_whatsapp_connector(stub_http: false) do
      Net::HTTP.stub(:start, ->(*, **) { raise Net::ReadTimeout }) do
        assert_equal %w[unknown connector_timeout], CommsConnector.send_text(@send).to_h.values_at(:status, :error_code)
      end
      Net::HTTP.stub(:start, ->(*, **) { raise Errno::ECONNRESET }) do
        assert_equal %w[unknown connector_unreachable], CommsConnector.send_text(@send).to_h.values_at(:status, :error_code)
      end
    end
  end

  test "a 401 is the connector's verifier refusing before it does anything: failed" do
    assert_equal %w[failed connector_refused_signature], answer(401, { error: "bad_signature" }).first.to_h.values_at(:status, :error_code)
  end

  test "a command that never left Rails is failed: no connector, no command key, no mutual TLS, plain http" do
    assert_equal %w[failed connector_not_configured], CommsConnector.send_text(@send).to_h.values_at(:status, :error_code)
    never = ->(*, **) { flunk "no request may be made" }
    with_whatsapp_connector(key: nil, stub_http: false) do
      Net::HTTP.stub(:start, never) { assert_equal %w[failed connector_misconfigured], CommsConnector.send_text(@send).to_h.values_at(:status, :error_code) }
    end
    with_whatsapp_connector(tls: [], stub_http: false) do
      Net::HTTP.stub(:start, never) { assert_equal %w[failed connector_misconfigured], CommsConnector.send_text(@send).to_h.values_at(:status, :error_code) }
    end
    with_whatsapp_connector(url: "http://souls-house-comms-whatsapp:8443", stub_http: false) do
      Net::HTTP.stub(:start, never) { assert_equal %w[failed connector_misconfigured], CommsConnector.send_text(@send).to_h.values_at(:status, :error_code) }
    end
  end

  test "neither the text nor the chat reaches the Rails log" do
    io = StringIO.new
    logger = ActiveSupport::Logger.new(io)
    Rails.stub(:logger, logger) do
      answer(200, { status: "sent", message_id: @send.provider_message_id, sent_at: "2026-10-24T10:00:01Z" })
      CommsConnector.send_text(@send) # unconfigured: logs nothing either
    end
    assert_no_match "On my way", io.string
    assert_no_match "447700900123", io.string
  end

  private

  # Calls send_text against a fake connector answering status/body; returns
  # the outcome and the request it got.
  def answer(status, body)
    seen = nil
    outcome = nil
    with_whatsapp_connector(stub_http: false) do
      fake = Object.new
      fake.define_singleton_method(:request) do |request|
        seen = request
        Net::HTTPResponse::CODE_TO_OBJ[status.to_s].new("1.1", status.to_s, "").tap do |response|
          response.instance_variable_set(:@read, true)
          response.instance_variable_set(:@body, body.is_a?(String) ? body : JSON.generate(body))
        end
      end
      Net::HTTP.stub(:start, ->(_host, _port, **_options, &block) { block.call(fake) }) do
        outcome = CommsConnector.send_text(@send)
      end
    end
    [ outcome, seen ]
  end

end
