# One message in a CommsChat. Media are not downloaded in milestone 1:
# media_kind records what it was ("image", "voice_note", ...) and the caption
# is kept.
#
# A provider message id is unique within its chat, not its connection:
# Telegram numbers channel and supergroup messages per peer. An edit replaces
# body and caption (edit_version orders edits). A deletion keeps the row as
# a tombstone with the content blanked; nothing brings the content back.
#
# comms_send links a message a resident sent through the house (an echo of
# our own message) to its CommsSend. It is attribution, not content: set by
# whichever of the echo and the send's acknowledgement arrives second,
# never changed by an edit, a deletion or a placeholder being filled, and
# the body is never rewritten for it.
class CommsMessage < ApplicationRecord

  belongs_to :service_connection
  belongs_to :comms_chat
  belongs_to :comms_send, optional: true

  encrypts :sender_id, :sender_name, :body, :caption

  validates :provider_message_id, presence: true, uniqueness: { scope: :comms_chat_id }
  validates :sent_at, presence: true
  validate :chat_on_same_connection

  # The echo side of echo-after-ack, for every way a row can first appear
  # (a message, or the placeholder an edit or deletion leaves). Runs inside
  # the event's transaction, under the connection's row lock.
  after_create :link_to_send

  def deleted?
    deleted_at.present?
  end

  def tombstone!(at:)
    return if deleted?

    update!(deleted_at: at, body: nil, caption: nil)
  end

  def as_comms_json
    json = {
      provider_message_id: provider_message_id,
      chat: comms_chat.provider_chat_id,
      sender_id: sender_id,
      sender_name: sender_name,
      sent_at: sent_at.utc.iso8601,
      body: body,
      media_kind: media_kind,
      caption: caption
    }
    json[:edited_at] = edited_at.utc.iso8601 if edited_at
    json[:deleted] = true if deleted?
    # An edit or deletion that arrived before the original: sent_at and the
    # sender are not known yet.
    json[:provisional] = true if placeholder?
    if comms_send
      json[:sent_by] = { resident_id: comms_send.agent.to_param, resident_name: comms_send.agent.name, send_id: comms_send.public_id }
    end
    json
  end

  private

  def link_to_send
    CommsSending.link_message!(self)
  end

  def chat_on_same_connection
    return unless comms_chat && service_connection_id
    errors.add(:comms_chat, "must belong to the same connection") unless comms_chat.service_connection_id == service_connection_id
  end

end
