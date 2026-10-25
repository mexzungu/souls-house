# Keeps the bytes of a single-image attachment (an avatar, the site logo)
# when it is removed or replaced (issue #93). The displaced blob stays
# attached to the same owner under a history name, so the attachment row
# itself is the owner/version link: record, history name, created_at, blob.
#
# While that row exists every purge path leaves the bytes alone:
# ActiveStorage::Blob refuses to destroy a blob that still has an attachment
# and Blob#purge swallows the refusal, so the purge queued by has_one
# replacement, or by an older queued job, is a no-op.
#
# Old signed URLs are hidden by HidesDiscardedBlobs: a blob whose only
# attachments are history rows has no live owner.
#
# Destroying the owner itself still removes its history links (dependent:
# :purge_later), and with them the bytes of any blob attached nowhere else. A
# blob still attached to another record keeps its bytes. Owner deletion is
# the explicit administrative deletion of the whole record, a separate #93
# slice.
module RetainsReplacedAttachment

  extend ActiveSupport::Concern

  class_methods do
    def retains_replaced_attachment(name, history:)
      name = name.to_s
      history = history.to_s

      has_many_attached history.to_sym

      # Replacement (or `name = nil`) through a normal save: keep the current
      # blob before has_one replacement destroys its attachment row.
      before_save { retain_attachment(name, history) if attachment_changes.key?(name) }

      define_method(:"retire_#{name}!") { retire_attachment!(name, history) }
      define_method(:"restore_retired_#{name}!") { |blob| restore_retired_attachment!(name, history, blob) }
    end
  end

  private

  def retain_attachment(name, history)
    current = public_send(:"#{name}_attachment")
    return if current.nil? || current.blob_id.nil?
    return if attachment_changes[name].respond_to?(:blob) && attachment_changes[name].blob&.id == current.blob_id

    ActiveStorage::Attachment.find_or_create_by!(record: self, name: history, blob_id: current.blob_id)
  end

  # Removal without a full save, so unrelated validation state on the owner
  # cannot block it (the purge it replaces did not validate either).
  def retire_attachment!(name, history)
    current = public_send(:"#{name}_attachment")
    return false if current.nil?

    transaction do
      retain_attachment(name, history)
      current.delete
      touch
    end
    association(:"#{name}_attachment").reset
    association(:"#{name}_blob").reset
    association(:"#{history}_attachments").reset
    true
  end

  # Administrative recovery: make a retained blob current again. The image it
  # displaces is retained in turn, so recovery never loses anything.
  def restore_retired_attachment!(name, history, blob)
    retained = public_send(:"#{history}_attachments").find_by!(blob_id: blob.is_a?(ActiveStorage::Blob) ? blob.id : blob)

    transaction do
      public_send(:"#{name}=", retained.blob)
      save!
      retained.delete
    end
    association(:"#{history}_attachments").reset
    true
  end

end
