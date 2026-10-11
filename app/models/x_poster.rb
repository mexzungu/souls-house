# Posts one tweet for a resident to its own account's connected X handle.
#
# The account comes only from the resident (agent.account), never from a
# request parameter. Every post needs an idempotency key: a repeated key
# returns the stored outcome and never posts again. The enabled switch and the
# daily ceiling are checked under a row lock on the integration, and the
# pending row is written inside that lock, so concurrent requests cannot
# overshoot. A post whose fate we cannot know (timeout after sending, broken
# connection, 5xx, unreadable 2xx) is stored as outcome_unknown and is never
# retried automatically; someone has to resolve it.
class XPoster

  class Refused < StandardError

    attr_reader :code, :http_status

    def initialize(code, message, http_status)
      @code = code
      @http_status = http_status
      super(message)
    end

  end

  Result = Struct.new(:log, :replayed, keyword_init: true)

  MAX_KEY_LENGTH = 200
  TWEET_ID_PATTERN = /\A\d{1,25}\z/

  # Errors raised before any byte of the request is sent: the post cannot
  # have happened.
  CONNECT_ERRORS = [ Net::OpenTimeout, SocketError, SystemCallError, OpenSSL::SSL::SSLError, IOError ].freeze
  # Errors raised while sending or waiting for the answer: X may have posted.
  IN_FLIGHT_ERRORS = [ Net::ReadTimeout, Net::WriteTimeout, EOFError, IOError, SystemCallError, OpenSSL::SSL::SSLError ].freeze

  def initialize(agent:)
    @agent = agent
    @account = agent.account
  end

  def post!(text:, idempotency_key:, reply_to: nil)
    text = text.to_s.strip
    reply_to = reply_to.to_s.strip.presence
    validate!(text:, idempotency_key:, reply_to:)

    log, replayed = reserve!(text:, idempotency_key:, reply_to:)
    return Result.new(log:, replayed: true) if replayed

    access_token = refreshed_access_token(log)
    deliver!(log, access_token) if access_token
    Result.new(log: log.reload, replayed: false)
  end

  private

  attr_reader :agent, :account

  def validate!(text:, idempotency_key:, reply_to:)
    if idempotency_key.blank? || idempotency_key.length > MAX_KEY_LENGTH
      raise Refused.new("idempotency_key_required", "An Idempotency-Key header (1-#{MAX_KEY_LENGTH} characters) is required", :bad_request)
    end
    raise Refused.new("text_blank", "Text is empty", :unprocessable_entity) if text.blank?

    length = XTextLength.weighted_length(text)
    if length > XTextLength::MAX_WEIGHTED_LENGTH
      raise Refused.new("text_too_long", "Text is #{length} weighted characters; X allows #{XTextLength::MAX_WEIGHTED_LENGTH}", :unprocessable_entity)
    end
    if reply_to && !reply_to.match?(TWEET_ID_PATTERN)
      raise Refused.new("invalid_reply_to", "reply_to must be a numeric tweet id", :unprocessable_entity)
    end
  end

  def reserve!(text:, idempotency_key:, reply_to:)
    integration = XIntegration.find_by(account_id: account.id)
    raise Refused.new("not_connected", "This account has no connected X handle", :forbidden) unless integration

    digest = Digest::SHA256.hexdigest({ text:, reply_to: }.to_json)

    XIntegration.transaction do
      integration.lock!

      existing = TweetLog.find_by(agent:, idempotency_key:)
      if existing
        unless existing.request_digest == digest
          raise Refused.new("idempotency_key_reused", "This Idempotency-Key was already used for a different post", :unprocessable_entity)
        end
        return [ existing, true ]
      end

      raise Refused.new("not_connected", "This account has no connected X handle", :forbidden) unless integration.connected?
      raise Refused.new("posting_disabled", "Posting to X is turned off for this account", :forbidden) unless integration.enabled?

      used = integration.tweet_logs.counting_toward_limit.where(created_at: 24.hours.ago..).count
      if used >= integration.daily_post_limit
        raise Refused.new("daily_limit_reached", "This account has used its #{integration.daily_post_limit} X posts for the last 24 hours", :too_many_requests)
      end

      log = integration.tweet_logs.create!(
        agent:, text:, reply_to_tweet_id: reply_to, idempotency_key:,
        request_digest: digest, status: "pending"
      )
      [ log, false ]
    end
  end

  # Refresh under the same row lock, so two posts never spend one rotating
  # refresh token twice. Returns nil (and marks the log failed) when the
  # token cannot be refreshed; nothing has been sent to X at that point.
  def refreshed_access_token(log)
    integration = log.x_integration
    XIntegration.transaction do
      integration.lock!
      integration.refresh_tokens!
      integration.access_token
    end
  rescue XApi::Error, ArgumentError, JSON::ParserError, *CONNECT_ERRORS, Net::ReadTimeout => e
    log.update!(status: "failed", failure_reason: "token_refresh_failed", error_message: e.message.truncate(500))
    nil
  end

  def deliver!(log, access_token)
    uri = URI("#{XApi::X_API_BASE}/tweets")
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.open_timeout = 10
    http.read_timeout = 30
    http.write_timeout = 30
    http.max_retries = 0

    begin
      http.start
    rescue *CONNECT_ERRORS => e
      return log.update!(status: "failed", failure_reason: "unreachable", error_message: e.message.truncate(500))
    end

    request = Net::HTTP::Post.new(uri)
    request["Authorization"] = "Bearer #{access_token}"
    request["Content-Type"] = "application/json"
    body = { text: log.text }
    body[:reply] = { in_reply_to_tweet_id: log.reply_to_tweet_id } if log.reply_to_tweet_id
    request.body = body.to_json

    begin
      response = http.request(request)
    rescue *IN_FLIGHT_ERRORS => e
      return unknown!(log, "#{e.class}: #{e.message}")
    ensure
      http.finish if http.started?
    end

    record_response!(log, response)
  end

  def record_response!(log, response)
    code = response.code.to_i
    detail = error_detail(response)

    case code
    when 200..299
      tweet_id = begin
        JSON.parse(response.body.to_s).dig("data", "id")
      rescue JSON::ParserError
        nil
      end
      return unknown!(log, "X answered #{code} without a readable tweet id") unless tweet_id.to_s.match?(TWEET_ID_PATTERN)

      log.update!(status: "posted", tweet_id: tweet_id.to_s)
    when 401
      log.update!(status: "failed", failure_reason: "unauthorized", error_message: "X rejected the access token; reconnect the account. #{detail}".strip)
    when 403
      log.update!(status: "failed", failure_reason: "forbidden", error_message: "X refused the post (missing tweet.write scope, app access level, or duplicate text). #{detail}".strip)
    when 429
      reset = response["x-rate-limit-reset"].to_i
      reset_at = Time.zone.at(reset).iso8601 if reset.positive?
      log.update!(status: "failed", failure_reason: "rate_limited", error_message: [ "X rate limit reached", (reset_at && "until #{reset_at}"), detail ].compact.join(" ").strip)
    when 400..499
      log.update!(status: "failed", failure_reason: "rejected", error_message: "X rejected the post (#{code}). #{detail}".strip)
    else
      unknown!(log, "X answered #{code}. #{detail}".strip)
    end
  end

  def unknown!(log, message)
    log.update!(status: "outcome_unknown", failure_reason: "outcome_unknown", error_message: message.truncate(500))
  end

  def error_detail(response)
    data = JSON.parse(response.body.to_s)
    [ data["title"], data["detail"], *Array(data["errors"]).map { |error| error["message"] || error["detail"] } ].compact.uniq.join(": ").truncate(300)
  rescue JSON::ParserError, TypeError
    ""
  end

end
