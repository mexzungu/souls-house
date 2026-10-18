# A chat voice recording stored by Chats::TranscriptionsController, kept so a
# failed transcription can be retried without recording again.
#
# The blob's metadata names who made it and where. Only that person, in that
# account and for that same chat (or, for a recording made before the chat
# existed, only from the new-conversation form), may retry or discard it, and
# only while it is not attached to a message. A recording made on the
# new-conversation form that is sent becomes the first message's attachment;
# it is never moved between chats. AbandonedAppUploadsJob removes unsent ones
# after RETENTION.
module VoiceNote

  METADATA_KEY = "voice_note".freeze
  RETENTION = 7.days

  def self.metadata_for(user:, account:, chat: nil)
    { "user_id" => user.id, "account_id" => account.id, "chat_id" => chat&.id }
  end

  def self.owned_by?(blob, user:, account:, chat:)
    note = blob.metadata[METADATA_KEY]
    note.is_a?(Hash) &&
      note["user_id"] == user.id &&
      note["account_id"] == account.id &&
      note["chat_id"] == chat&.id
  end

  def self.retryable_by?(blob, user:, account:, chat:)
    owned_by?(blob, user:, account:, chat:) && !attached?(blob)
  end

  def self.attached?(blob)
    ActiveStorage::Attachment.exists?(blob_id: blob.id)
  end

  def self.expires_at(blob)
    blob.created_at + RETENTION
  end

  # Removes the recording unless a message has taken it. The row is locked and
  # the attachment rechecked under the lock, as the sweep does, so a send that
  # is attaching it concurrently wins. Returns true when it was removed.
  def self.discard!(blob)
    removed = ActiveStorage::Blob.transaction do
      locked = ActiveStorage::Blob.lock("FOR UPDATE").find_by(id: blob.id)
      next false unless locked
      next nil if attached?(locked)

      locked.destroy!
      locked
    end
    return removed if removed.nil? || removed == false

    # Committed first: a reader must see a missing row, never bytes without one.
    removed.delete
    true
  end

end
