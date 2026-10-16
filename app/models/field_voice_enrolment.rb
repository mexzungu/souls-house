# A pending "remember this voice" (spec §9): who agreed, which sample, and,
# after "use it", the vendor job. Forget deletes it; every step rechecks it.
class FieldVoiceEnrolment < ApplicationRecord

  include ObfuscatesId

  STATUSES = %w[previewing dispatched].freeze

  belongs_to :account
  belongs_to :field_voice
  belongs_to :field_recording_speaker
  belongs_to :consented_by, polymorphic: true, optional: true

  has_one_attached :sample

  validates :status, inclusion: { in: STATUSES }

  # The cross-account operator restore is explicitly a reconnect snapshot.
  attr_accessor :skip_broadcast

  after_save :refresh_recordings, if: -> {
    attachment_changes.key?("sample") ||
      (saved_changes.keys & %w[id field_recording_speaker_id status sample_ms expires_at]).any?
  }
  before_destroy { refresh_recordings(destroying: true) }
  before_destroy { sample.purge_later if sample.attached? }

  def expired?(now = Time.current) = expires_at <= now

  private

  def refresh_recordings(destroying: false)
    return if skip_broadcast

    speaker_ids = destroying ? [ field_recording_speaker_id ] :
      [ field_recording_speaker_id, field_recording_speaker_id_before_last_save ].compact.uniq
    recording_ids = FieldRecordingSpeaker.where(id: speaker_ids).distinct.pluck(:field_recording_id)
    FieldRecordingActivity.refresh!(recording_ids)
  end

end
