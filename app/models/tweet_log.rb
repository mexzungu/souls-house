class TweetLog < ApplicationRecord

  STATUSES = %w[pending posted failed outcome_unknown resolved_posted resolved_not_posted].freeze
  # Everything that did or may have become a public post counts toward the
  # account's daily ceiling; only definite failures do not.
  COUNTING_STATUSES = %w[pending posted outcome_unknown resolved_posted].freeze

  belongs_to :x_integration
  belongs_to :agent
  belongs_to :resolved_by_agent, class_name: "Agent", optional: true

  validates :tweet_id, uniqueness: true, allow_nil: true
  validates :tweet_id, presence: true, if: -> { status.in?(%w[posted resolved_posted]) }
  validates :text, presence: true
  validates :status, inclusion: { in: STATUSES }

  scope :recent, -> { order(created_at: :desc) }
  scope :counting_toward_limit, -> { where(status: COUNTING_STATUSES) }
  scope :outcome_unknown, -> { where(status: "outcome_unknown") }

  def url
    return unless tweet_id

    handle = x_integration.x_username.presence || "i/web"
    "https://x.com/#{handle}/status/#{tweet_id}"
  end

  def resolve!(resolution:, by:, tweet_id: nil)
    with_lock do
      raise ArgumentError, "Only a post whose outcome is unknown can be resolved" unless status == "outcome_unknown"

      case resolution
      when "posted"
        raise ArgumentError, "A numeric tweet id is required" unless tweet_id.to_s.match?(XPoster::TWEET_ID_PATTERN)

        update!(status: "resolved_posted", tweet_id: tweet_id.to_s, resolved_at: Time.current, resolved_by_agent: by)
      when "not_posted"
        update!(status: "resolved_not_posted", resolved_at: Time.current, resolved_by_agent: by)
      else
        raise ArgumentError, "resolution must be posted or not_posted"
      end
    end
  end

  def as_post_json
    {
      id: to_param,
      status:,
      text:,
      reply_to: reply_to_tweet_id,
      tweet_id:,
      url:,
      failure_reason:,
      error: error_message,
      created_at: created_at&.iso8601,
      resolved_at: resolved_at&.iso8601
    }
  end

end
