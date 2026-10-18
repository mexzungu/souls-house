class AbandonedAppUploadsJob < ApplicationJob

  queue_as :default

  BATCH_SIZE = 100
  RETENTION = 24.hours

  def perform(now: Time.current)
    cutoff = now - RETENTION
    # Active Storage serializes metadata as JSON in a text column. Cast
    # explicitly so nested keys cannot fill the batch and starve real uploads.
    # Authority still comes from the parsed metadata checked under the lock.
    ids = ActiveStorage::Blob.unattached
      .where(created_at: ...cutoff)
      .where("metadata::jsonb ? 'app_upload'")
      .order(:id).limit(BATCH_SIZE).pluck(:id)

    ids.each do |id|
      deleted = ActiveStorage::Blob.transaction do
        blob = ActiveStorage::Blob.lock("FOR UPDATE SKIP LOCKED").find_by(id: id)
        next unless blob && blob.metadata.key?("app_upload") && blob.created_at < cutoff
        next if ActiveStorage::Attachment.exists?(blob_id: blob.id)

        blob.destroy!
        blob
      end

      # Commit the removal before touching storage: claimers must observe a
      # missing row, never a rollback that resurrects a blob without its bytes.
      # Blob#delete also removes image variants, as Blob#purge does.
      deleted&.delete
    end
  end

end
