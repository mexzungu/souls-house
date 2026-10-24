require "net/http"

# Rails → comms connector commands, and WhatsApp's send_text (the only
# command whose answer is an outcome rather than an acknowledgement).
#
# Every command, for every provider, goes over mutual TLS and is signed with
# the connector-wide COMMS_COMMAND_KEY (CommsCommandSignature), because some
# carry secrets: start_pairing / start_login hand the connector the
# connection's callback secret (proposal 2026-10-11 §5, which settles the
# WhatsApp proposal's open "secret bootstrap"). The connector cannot verify a
# command with a secret it does not hold yet, so the per-connection secret is
# only ever used for connector → Rails events (CommsSignature).
#
# WhatsApp and Telegram are separate connectors (Go/whatsmeow and
# Python/Telethon), so each has its own URL: COMMS_WHATSAPP_CONNECTOR_URL and
# COMMS_CONNECTOR_URL. While a provider's URL is unset (development, tests,
# and every deploy before its accessory exists) a command is not sent; the
# intent is logged and :not_configured returned.
module CommsConnector

  COMMANDS = %w[start_pairing unpair pair_phone].freeze
  WHATSAPP_URL_ENV = "COMMS_WHATSAPP_CONNECTOR_URL".freeze
  # Everything a WhatsApp command needs; the catalog hides WhatsApp until all
  # of it is set.
  WHATSAPP_ENV = [ WHATSAPP_URL_ENV, "COMMS_COMMAND_KEY",
                   "COMMS_CONNECTOR_CLIENT_CERT", "COMMS_CONNECTOR_CLIENT_KEY", "COMMS_CONNECTOR_CA_FILE" ].freeze
  # The same for Telegram (services/telegram-connector).
  TELEGRAM_ENV = [ "COMMS_CONNECTOR_URL", "COMMS_COMMAND_KEY",
                   "COMMS_CONNECTOR_CLIENT_CERT", "COMMS_CONNECTOR_CLIENT_KEY", "COMMS_CONNECTOR_CA_FILE" ].freeze

  class Error < StandardError; end
  # pair_phone refused because the connector already took a newer request.
  class StaleRequest < Error; end
  # An unpair that could not be sent because no connector is configured.
  # Not a confirmation: the accessory outlives Rails deploys and its
  # configuration, so it may still hold the device.
  class NotConfigured < Error; end

  # The connector's answer to send_text, mapped to a CommsSend status:
  # "sent", "failed" or "unknown", nothing else. error_reason is the
  # connector's short machine reason for a provider refusal.
  SendOutcome = Data.define(:status, :provider_message_id, :sent_at, :error_code, :error_reason) do
    def self.unknown(code) = new(status: "unknown", provider_message_id: nil, sent_at: nil, error_code: code, error_reason: nil)
    def self.failed(code, reason = nil) = new(status: "failed", provider_message_id: nil, sent_at: nil, error_code: code, error_reason: reason)
  end

  # Explicit refusals in the send_text contract: nothing was sent.
  SEND_REFUSALS = {
    "409" => %w[not_connected stale_attempt],
    "422" => %w[bad_message_id bad_chat unsupported_chat bad_text send_mismatch refused]
  }.freeze
  SEND_READ_TIMEOUT = 30

  module_function

  # WhatsApp. start_pairing hands over the callback secret with its version;
  # the connector never installs a version lower than the one it holds.
  def start_pairing(connection)
    payload = connection.credential_payload_hash
    secret = payload["callback_secret"]
    raise Error, "#{connection.public_id} has no callback secret" if secret.blank?

    command(connection, "start_pairing", url: ENV[WHATSAPP_URL_ENV].presence,
                                         callback_secret: secret,
                                         callback_secret_version: [ payload["callback_secret_version"].to_i, 1 ].max)
  end

  def unpair(connection)
    command(connection, "unpair", url: ENV[WHATSAPP_URL_ENV].presence)
  end

  # WhatsApp: hand one CommsSend to the connector (contract in the WhatsApp
  # proposal, "Sending"). The connector records the send id as attempted
  # before calling WhatsApp and never sends the same id twice; message_id is
  # the WhatsApp message id Rails chose at claim time; attempt is the
  # pairing attempt the send was claimed under (the value start_pairing
  # carries), which the connector checks against its live session.
  #
  # Only the connector's explicit answer becomes sent or failed. A timeout,
  # a lost connection, a 5xx, an unparseable or unrecognised answer, and the
  # connector's own outcome_unknown, are unknown: the message may or may not
  # have gone. A command that could not be built (no connector configured,
  # no command key, no mutual TLS) never left Rails, so it is failed.
  def send_text(send)
    connection = send.service_connection
    url = ENV[WHATSAPP_URL_ENV].presence
    return SendOutcome.failed("connector_not_configured") unless url

    begin
      prepared = prepare_command(connection, "send_text", url:,
                                                          attempt: send.connection_generation,
                                                          send_id: send.public_id,
                                                          message_id: send.provider_message_id,
                                                          chat: send.comms_chat.provider_chat_id,
                                                          text: send.text)
    rescue Error
      return SendOutcome.failed("connector_misconfigured")
    end

    send_outcome(perform(prepared, read_timeout: SEND_READ_TIMEOUT))
  rescue Timeout::Error
    SendOutcome.unknown("connector_timeout")
  rescue SystemCallError, IOError, OpenSSL::SSL::SSLError, SocketError
    SendOutcome.unknown("connector_unreachable")
  rescue StandardError
    SendOutcome.unknown("connector_error")
  end

  def send_outcome(response)
    body = begin
      JSON.parse(response.body.to_s)
    rescue JSON::ParserError
      nil
    end
    body = {} unless body.is_a?(Hash)
    error = body["error"].to_s

    if response.code == "200" && body["status"] == "sent" && body["message_id"].is_a?(String) && body["message_id"].present?
      sent_at = begin
        Time.iso8601(body["sent_at"].to_s)
      rescue ArgumentError
        nil
      end
      SendOutcome.new(status: "sent", provider_message_id: body["message_id"].first(128), sent_at:, error_code: nil, error_reason: nil)
    elsif SEND_REFUSALS.fetch(response.code, []).include?(error)
      reason = body["reason"].to_s.gsub(/[^a-z0-9_.:-]/i, "").first(64).presence if error == "refused"
      SendOutcome.failed(error, reason)
    elsif response.code == "409" && error == "outcome_unknown"
      SendOutcome.unknown("outcome_unknown")
    elsif response.is_a?(Net::HTTPSuccess)
      SendOutcome.unknown("connector_unrecognised")
    else
      SendOutcome.unknown("connector_http_#{response.code.to_s.gsub(/\D/, "").first(3)}")
    end
  end

  # WhatsApp's "Link with phone number instead": ask the connection's
  # pairing session for a code for this number (E.164, already validated)
  # in this attempt. The connector accepts at once; the code follows as a
  # pairing.phone_code event. The number travels only in this signed body,
  # over mutual TLS; command logs only name the operation.
  # request: the id ServiceConnection#request_phone_pairing! minted for this
  # ask (never the number); the code or failure that answers names it.
  # seq: that ask's sequence number. The connector answers 409
  # stale_request when it has already accepted a newer ask (raised as
  # StaleRequest: Rails has moved on, so it is not a failure to send).
  def pair_phone(connection, phone_number, attempt:, request:, seq:)
    command(connection, "pair_phone", url: ENV[WHATSAPP_URL_ENV].presence, phone_number:, attempt:,
                                      request_id: request, request_seq: seq)
  end

  # Unpair, raising NotConfigured instead of returning :not_configured, for
  # callers that must only treat a real reply as confirmation.
  def unpair!(connection)
    result = unpair(connection)
    raise NotConfigured, "no WhatsApp connector is configured" if result == :not_configured

    result
  end

  # Telegram commands (proposal 2026-10-11 §5). Like WhatsApp's, some of
  # these carry secrets (the callback secret, a two-step password), so for
  # both providers:
  #
  # - the connector must be reached over https with mutual TLS: Rails's
  #   client certificate and key (COMMS_CONNECTOR_CLIENT_CERT/_KEY) and the
  #   house CA that signed the connector's (COMMS_CONNECTOR_CA_FILE). Plain
  #   http, or any of the three missing, sends nothing;
  # - each command is signed with the connector-wide COMMS_COMMAND_KEY (its
  #   id in COMMS_COMMAND_KEY_ID), over the connection, operation, a unique
  #   command id, the issue time and the body, so the connector can reject
  #   stale or replayed commands and commands for another connection.
  #
  # Returns the connector's JSON reply as a Hash, or :not_configured.
  TELEGRAM_COMMANDS = %w[start_login request_code submit_code submit_password cancel_login logout search].freeze

  def telegram_command(connection, operation, **fields)
    raise ArgumentError, "unknown telegram command #{operation}" unless TELEGRAM_COMMANDS.include?(operation)

    command(connection, operation, url: base_url, **fields)
  end

  def command(connection, operation, url:, **fields)
    unless url
      Rails.logger.info("[comms] connector not configured; #{operation} intended for #{connection.public_id}")
      return :not_configured
    end

    response = perform(prepare_command(connection, operation, url:, **fields))
    unless response.is_a?(Net::HTTPSuccess)
      raise StaleRequest, "comms connector #{operation}: a newer request was accepted" if stale_request?(operation, response)

      raise Error, "comms connector #{operation} failed (#{response.code})"
    end

    parsed = response.body.present? ? JSON.parse(response.body) : {}
    parsed.is_a?(Hash) ? parsed : {}
  rescue JSON::ParserError
    raise Error, "comms connector #{operation} returned invalid JSON"
  end

  PreparedCommand = Data.define(:uri, :tls, :request)

  # The signed request, or Error when it cannot be built (http, missing
  # mutual TLS settings, no command key). Nothing has been sent yet.
  def prepare_command(connection, operation, url:, **fields)
    uri = URI.join(url, "/connections/#{connection.public_id}/#{operation}")
    raise Error, "the comms connector must be reached over https" unless uri.scheme == "https"
    tls = tls_options

    issued_at = Time.current.to_i
    command_id = SecureRandom.hex(16)
    body = JSON.generate(fields.merge(connection: connection.public_id, operation:, command_id:, issued_at:))
    request = Net::HTTP::Post.new(uri)
    request["Content-Type"] = "application/json"
    CommsCommandSignature.headers_for(
      connection_id: connection.public_id, operation:, command_id:, issued_at:, body:
    ).each { |name, value| request[name] = value }
    request.body = body
    PreparedCommand.new(uri:, tls:, request:)
  rescue CommsCommandSignature::MissingKey => e
    raise Error, e.message
  end

  def perform(prepared, read_timeout: 30)
    Net::HTTP.start(prepared.uri.hostname, prepared.uri.port, **prepared.tls, open_timeout: 5, read_timeout:) do |http|
      http.request(prepared.request)
    end
  end

  def stale_request?(operation, response)
    return false unless operation == "pair_phone" && response.code == "409"

    body = JSON.parse(response.body.to_s)
    body.is_a?(Hash) && body["error"] == "stale_request"
  rescue JSON::ParserError
    false
  end

  TLS_SETTINGS = %w[COMMS_CONNECTOR_CLIENT_CERT COMMS_CONNECTOR_CLIENT_KEY COMMS_CONNECTOR_CA_FILE].freeze

  # Mutual TLS, failing closed: every setting present and readable, or no
  # command is sent.
  def tls_options
    missing = TLS_SETTINGS.select { |name| ENV[name].blank? }
    raise Error, "mutual TLS to the comms connector is not configured (#{missing.join(", ")})" if missing.any?

    {
      use_ssl: true,
      verify_mode: OpenSSL::SSL::VERIFY_PEER,
      ca_file: ENV["COMMS_CONNECTOR_CA_FILE"],
      cert: OpenSSL::X509::Certificate.new(File.read(ENV["COMMS_CONNECTOR_CLIENT_CERT"])),
      key: OpenSSL::PKey.read(File.read(ENV["COMMS_CONNECTOR_CLIENT_KEY"]))
    }
  rescue SystemCallError, OpenSSL::OpenSSLError => e
    raise Error, "mutual TLS to the comms connector is misconfigured (#{e.class})"
  end

  def base_url
    ENV["COMMS_CONNECTOR_URL"].presence
  end

end
