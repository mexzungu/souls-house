# A stored voice print (spec §9). Encrypted at rest (non-deterministic), never
# serialised: there is no JSON, prop or API shape that carries one, and asking
# for one raises. Destroyed, not discarded, when forgotten.
class FieldVoiceprint < ApplicationRecord

  belongs_to :field_voice
  belongs_to :account
  belongs_to :sample_recording, class_name: "FieldRecording", optional: true
  belongs_to :consented_by, polymorphic: true, optional: true

  encrypts :print

  validates :print, :generation, :sample_ms, :consented_at, :consent_text_version, presence: true

  # The print row is the producer even when its writer uses update_columns
  # on the voice generation. Print contents and vendor bookkeeping are not UI.
  after_save :refresh_presentation, if: -> {
    (saved_changes.keys & %w[id field_voice_id generation sample_ms consented_by_type consented_by_id consented_at]).any?
  }
  before_destroy { refresh_presentation(destroying: true) }

  # Current only while the voice hasn't moved on (forgotten or replaced).
  def current? = generation == field_voice.print_generation

  def serializable_hash(*)
    raise NotImplementedError, "voice prints are never serialised"
  end

  def inspect = "#<FieldVoiceprint id: #{id}, field_voice_id: #{field_voice_id}, generation: #{generation}>"

  private

  def refresh_presentation(destroying: false)
    voice_ids = destroying ? [ field_voice_id ] : [ field_voice_id, field_voice_id_before_last_save ].compact.uniq
    # Ownership follows the voices, not a stale print.account_id. Capture it
    # before destructive associations disappear.
    FieldVoiceActivity.refresh!(FieldVoice.where(id: voice_ids).distinct.pluck(:account_id))
    # Consent labels and dates are roster-only. Speaker cards read existence,
    # the generation and sample length, never consent attribution.
    return unless destroying || (saved_changes.keys & %w[id field_voice_id generation sample_ms]).any?

    recording_ids = FieldRecordingSpeaker.where(field_voice_id: voice_ids).distinct.pluck(:field_recording_id)
    FieldRecordingActivity.refresh!(recording_ids)
  end

end
