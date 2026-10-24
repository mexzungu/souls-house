# One message a resident asked to send through a comms connection, as the
# connection's owner (WhatsApp spec §5). The row is written before the
# connector is called, so a send that happened always has a record.
#
#   pending  claimed, not yet handed to the connector
#   unknown  handed to the connector with no definite outcome (a timeout,
#            a lost connection, a restart, or the connector itself saying
#            the outcome was never recorded); never retried automatically
#   sent     the connector reports the provider accepted it (not delivered
#            or read)
#   failed   the connector explicitly refused it, or the house refused it at
#            dispatch (refused_at_dispatch_*) before calling the connector
#
# provider_message_id is chosen by the provider's adapter at claim time and
# handed to the connector, so the echoed message (comms_messages) links to
# this record even when it arrives before the acknowledgement.
class CommsSend < ApplicationRecord

  STATUSES = %w[pending sent failed unknown].freeze
  MAX_TEXT_LENGTH = 4096
  # The connector bounds a command body at 16 KiB; 4096 four-byte characters
  # would not fit with the envelope.
  MAX_TEXT_BYTES = 12 * 1024
  CLIENT_REQUEST_ID_FORMAT = /\A[A-Za-z0-9._:-]{1,100}\z/

  belongs_to :service_connection
  belongs_to :agent
  belongs_to :comms_chat
  has_one :comms_message, dependent: :restrict_with_error

  encrypts :text, :sender_id, :sender_name

  validates :text, presence: true, length: { maximum: MAX_TEXT_LENGTH }
  validate :text_fits
  validates :client_request_id, format: { with: CLIENT_REQUEST_ID_FORMAT }
  validates :status, inclusion: { in: STATUSES }
  validates :requested_at, :provider_message_id, :connection_generation, presence: true
  validate :chat_on_same_connection

  def self.acceptable_text?(text)
    text.is_a?(String) && text.strip.present? && !text.include?("\u0000") &&
      text.length <= MAX_TEXT_LENGTH && text.bytesize <= MAX_TEXT_BYTES
  end

  def public_id
    "send_#{id}"
  end

  def same_request?(chat, text)
    comms_chat_id == chat.id && self.text == text
  end

  # What the resident who sent it sees.
  def as_comms_json
    {
      id: public_id,
      client_request_id: client_request_id,
      chat: comms_chat.provider_chat_id,
      status: status,
      provider_message_id: provider_message_id,
      error_code: error_code,
      error_reason: error_reason,
      requested_at: requested_at.utc.iso8601,
      sent_at: sent_at&.utc&.iso8601
    }.compact
  end

  # What the connection's owner sees: who said what, to whom, when.
  def as_owner_json
    as_comms_json.merge(
      resident_id: agent.to_param,
      resident_name: agent.name,
      chat_name: comms_chat.name,
      text: text,
      dispatched_at: dispatched_at&.utc&.iso8601
    )
  end

  private

  def text_fits
    errors.add(:text, "is too long") if text.is_a?(String) && text.bytesize > MAX_TEXT_BYTES
  end

  def chat_on_same_connection
    return unless comms_chat && service_connection_id
    errors.add(:comms_chat, "must belong to the same connection") unless comms_chat.service_connection_id == service_connection_id
  end

end
