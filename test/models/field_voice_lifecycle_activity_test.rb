require "test_helper"
require "support/field_recording_helpers"

class FieldVoiceLifecycleActivityTest < ActiveSupport::TestCase

  include ActionCable::TestHelper
  include FieldRecordingHelpers

  self.use_transactional_tests = false

  setup do
    @user = users(:user_1)
    @accounts = 2.times.map do
      account = Account.create!(name: "Voice lifecycle #{SecureRandom.hex(4)}", account_type: :team)
      account.add_user!(@user, role: "owner", skip_confirmation: true)
      account
    end
    @account, @foreign = @accounts
    @recordings = 3.times.map { long_ready_recording(account: @account, user: @user) }
    @recording, @suggested, @recognised = @recordings
    @speaker = @recording.speakers.first
    @voice = @account.field_voices.create!(name: "SECRET-NAME")
    @speaker.name_as!(@voice, by: @user)
    clear_enqueued_jobs
  end

  teardown do
    @recordings.each { |recording| recording.audio.purge if FieldRecording.exists?(recording.id) }
    @accounts.each { |account| account.reload.destroy! if Account.exists?(account.id) }
  end

  test "preview creation sample attachment dispatch and destruction refresh only its recording" do
    enrolment = nil
    assert_events(details: [ @recording ]) { enrolment = preview }
    assert_nil presentation[:pending_enrolment]
    assert_events(details: [ @recording ]) { attach_sample(enrolment) }
    assert presentation[:pending_enrolment][:sample_url].present?
    assert_events(details: [ @recording ]) { enrolment.update!(status: "dispatched", vendor_job_id: "SECRET-VENDOR") }
    assert presentation[:remembering]
    assert_events(details: [ @recording ]) { enrolment.destroy! }
    assert_not presentation[:remembering]
  end

  test "preview replacement and attachment batch coalesce at outer commit" do
    old = preview
    assert_events(details: [ @recording ]) do
      FieldVoiceEnrolment.transaction do
        assert_events do
          old.destroy!
          fresh = preview
          attach_sample(fresh)
          fresh.touch
          fresh.reload
        end
      end
    end
  end

  test "rendered enrolment fields refresh while vendor poll attribution and touches are quiet" do
    enrolment = preview
    { sample_ms: 16_000, expires_at: 2.hours.from_now, status: "dispatched" }.each do |field, value|
      assert_events(details: [ @recording ]) { enrolment.update!(field => value) }
    end
    hidden_voice = @account.field_voices.create!(name: "Hidden enrolment attribution")
    assert_events do
      enrolment.update!(vendor_job_id: "SECRET-VENDOR", poll_count: 3, consented_by: @user,
        field_voice: hidden_voice, start_generation: 42, decision_generation: 43, consent_text_version: "not rendered")
      enrolment.touch
      enrolment.save!
      assert_not enrolment.update(status: "invalid")
    end
  end

  test "enrolment reassignment captures old and new recordings before speaker destruction" do
    enrolment = preview
    other_speaker = @suggested.speakers.first
    assert_events(details: [ @recording, @suggested ]) { enrolment.update!(field_recording_speaker: other_speaker) }
    assert_events(details: [ @suggested ]) { other_speaker.destroy! }
    assert_not FieldVoiceEnrolment.exists?(enrolment.id)
  end

  test "enrolment changes and destruction roll back at outer and savepoint boundaries" do
    enrolment = preview
    assert_events do
      FieldVoiceEnrolment.transaction do
        attach_sample(enrolment)
        enrolment.update!(status: "dispatched")
        enrolment.destroy!
        raise ActiveRecord::Rollback
      end
      FieldVoiceEnrolment.transaction do
        FieldVoiceEnrolment.transaction(requires_new: true) do
          enrolment.reload.destroy!
          raise ActiveRecord::Rollback
        end
      end
    end
    assert_events(details: [ @recording ]) { FieldVoiceEnrolment.find(enrolment.id).update!(sample_ms: 18_000) }
  end

  test "print creation metadata updates and destruction refresh remembered roster and linked details" do
    print = nil
    assert_events(details: [ @recording ], rosters: [ @account ]) { print = store_print!(@voice) }
    assert presentation[:remembered]
    { sample_ms: 20_000, generation: 4 }.each do |field, value|
      assert_events(details: [ @recording ], rosters: [ @account ]) { print.update!(field => value) }
    end
    { consented_by: @user, consented_at: 1.minute.ago }.each do |field, value|
      assert_events(rosters: [ @account ]) { print.update!(field => value) }
    end
    assert_events do
      print.update!(print: "SECRET-PRINT", consent_text_version: "not rendered", sample_recording: @suggested)
      print.touch
    end
    assert_events(details: [ @recording ], rosters: [ @account ]) { print.destroy! }
    assert_not presentation[:remembered]
  end

  test "print reassignment and stale account ownership use old and new voice owners" do
    foreign_voice = @foreign.field_voices.create!(name: "Foreign name")
    print = store_print!(@voice)
    assert_events(details: [ @recording ], rosters: [ @account, @foreign ]) do
      print.update!(field_voice: foreign_voice)
    end
    assert_equal @account.id, print.account_id, "exercise deliberately stale print ownership"
    assert_events(rosters: [ @foreign ]) { FieldVoiceprint.find(print.id).destroy! }
  end

  test "successful write back coalesces print and enrolment producers despite generation update_columns" do
    with_recognition(@account) do
      enrolment = preview
      attach_sample(enrolment)
      client = FakePyannote.new
      assert_events(details: [ @recording ]) { FieldVoiceprints::Enrolments.dispatch!(enrolment, client:) }
      assert_events(details: [ @recording ], rosters: [ @account ]) do
        assert FieldVoiceprints::Enrolments.write_back!(enrolment.id, "SECRET-PRINT")
      end
      assert presentation[:remembered]
      assert_not presentation[:remembering]
      assert_nil presentation[:pending_enrolment]
    end
  end

  test "uncertain dispatch and refused write back remove pending presentation" do
    with_recognition(@account) do
      enrolment = preview
      attach_sample(enrolment)
      client = Object.new
      def client.voiceprint(url:) = raise(PyannoteClient::TransientError, "uncertain")
      assert_events(details: [ @recording ]) do
        assert_raises(FieldVoiceprints::Enrolments::Uncertain) { FieldVoiceprints::Enrolments.dispatch!(enrolment, client:) }
      end
      enrolment = preview(status: "dispatched")
      @voice.update_columns(print_generation: @voice.print_generation + 1)
      assert_events(details: [ @recording ]) do
        assert_not FieldVoiceprints::Enrolments.write_back!(enrolment.id, "SECRET-PRINT")
      end
    end
  end

  test "forget captures recognised recordings before bulk clear and preserves names" do
    store_print!(@voice)
    preview
    recognise(@recognised)
    @recognised.update_columns(status: "queued")
    assert_events(details: [ @recording, @recognised ], rosters: [ @account ]) { @voice.forget! }
    assert_nil @recognised.speakers.first.reload.recognised_voice_id
    assert_equal @voice, @speaker.reload.field_voice
    assert_not presentation[:remembered]
  end

  test "deleting a name captures linked union suggested union recognised even without rerender changes" do
    @voice.update!(name: @speaker.default_name)
    @recording.update!(transcript_text: @recording.render_transcript_text)
    text = @recording.reload.transcript_text
    @suggested.speakers.first.update!(suggested_voice: @voice, suggested_name: "Suggestion", suggestion_generation: 0)
    recognise(@recognised)
    @recording.update_columns(status: "queued")
    @suggested.update_columns(status: "queued")
    assert_events(details: @recordings, rosters: [ @account ]) { @voice.delete_identity! }
    assert_equal text, @recording.reload.transcript_text
    assert_nil @speaker.reload.field_voice_id
    assert_nil @suggested.speakers.first.reload.suggested_voice_id
    assert_nil @recognised.speakers.first.reload.recognised_voice_id
  end

  test "forget all preserves per voice transactions and has an N voice bound" do
    second_voice = @account.field_voices.create!(name: "Second")
    @recording.speakers.last.name_as!(second_voice, by: @user)
    store_print!(@voice)
    store_print!(second_voice)
    unremembered = @account.field_voices.create!(name: "No print")
    assert_events(details: [ @recording, @recording ], rosters: [ @account, @account ]) do
      FieldVoiceprints.forget_all!(@account)
    end
    assert_equal 1, unremembered.reload.print_generation
  end

  test "generation only forget is silent even with linked names" do
    assert_events { @voice.forget! }
    assert_equal 1, @voice.reload.print_generation
  end

  test "forget invalidations never write or lock recording rows under the voice lock" do
    store_print!(@voice)
    preview
    recognise(@recognised)
    queries = []
    observer = ->(*args) { queries << args.last[:sql] }
    ActiveSupport::Notifications.subscribed(observer, "sql.active_record") do
      assert_events(details: [ @recording, @recognised ], rosters: [ @account ]) { @voice.forget! }
    end
    recording_writes = queries.grep(/(?:UPDATE|DELETE FROM|INSERT INTO) "field_recordings"|FROM "field_recordings".*FOR UPDATE/i)
    assert_empty recording_writes
  end

  test "expiry is a read snapshot until the existing sweep destroys the preview" do
    enrolment = preview
    attach_sample(enrolment)
    assert presentation[:pending_enrolment]
    travel 2.hours do
      assert_events { assert_nil presentation[:pending_enrolment] }
      assert_events(details: [ @recording ]) { FieldVoices::EnrolmentSweepJob.perform_now }
    end
    assert_not FieldVoiceEnrolment.exists?(enrolment.id)
  end

  test "bulk forget and delete rollbacks restore all state without leaking hints" do
    store_print!(@voice)
    preview
    recognise(@recognised)
    @suggested.speakers.first.update!(suggested_voice: @voice, suggested_name: "Suggestion")
    assert_events do
      FieldVoice.transaction do
        @voice.delete_identity!
        raise ActiveRecord::Rollback
      end
      FieldVoice.transaction do
        FieldVoice.transaction(requires_new: true) do
          @voice.reload.forget!
          raise ActiveRecord::Rollback
        end
      end
    end
    assert @voice.reload.remembered?
    assert @voice.kept?
    assert_equal @voice.id, @recognised.speakers.first.reload.recognised_voice_id
    assert_equal @voice.id, @suggested.speakers.first.reload.suggested_voice_id
    assert_equal 1, @speaker.enrolments.count
    assert_events(details: [ @recording, @recognised ], rosters: [ @account ]) { @voice.forget! }
  end

  test "print batches coalesce per account and recording and rollback never poisons later writes" do
    print = store_print!(@voice)
    assert_events(details: [ @recording ], rosters: [ @account ]) do
      FieldVoiceprint.transaction do
        print.update!(sample_ms: 18_000)
        FieldVoiceprint.transaction(requires_new: true) do
          print.update!(sample_ms: 22_000)
          raise ActiveRecord::Rollback
        end
        FieldVoiceprint.find(print.id).update!(consented_at: 2.minutes.ago)
        assert_events { print.reload.touch }
      end
    end
    assert_equal 18_000, print.reload.sample_ms
    assert_events do
      FieldVoiceprint.transaction do
        FieldVoiceprint.transaction(requires_new: true) { print.destroy! }
        raise ActiveRecord::Rollback
      end
    end
    assert_events(details: [ @recording ], rosters: [ @account ]) { print.reload.destroy! }
  end

  test "operator restore is a refresh snapshot with no cross account live fanout" do
    store_print!(@voice)
    preview
    recognise(@recognised)
    assert_events { FieldVoiceprints.reset_all! }
    assert_not @voice.reload.remembered?
    assert_empty @speaker.enrolments
  end

  test "committed savepoints defer hints to the outer commit with the established bounded count" do
    print = store_print!(@voice)
    assert_events(details: [ @recording, @recording ], rosters: [ @account, @account ]) do
      FieldVoiceprint.transaction do
        assert_events do
          print.update!(sample_ms: 18_000)
          FieldVoiceprint.transaction(requires_new: true) { print.update!(sample_ms: 20_000) }
        end
      end
    end
  end

  test "delete keeps the existing changed transcript broadcast as well as its explicit bulk hint" do
    assert_events(details: [ @recording, @recording ], rosters: [ @account ]) { @voice.delete_identity! }
    assert_match "Speaker 1:", @recording.reload.transcript_text
  end

  test "a refresh does not cut dispatch identify or enqueue work" do
    PyannoteClient.stub(:new, ->(*) { flunk "no vendor client from presentation" }) do
      FieldVoiceprints::Sample.stub(:cut, ->(*) { flunk "no sample work from presentation" }) do
        assert_no_enqueued_jobs do
          assert_events(rosters: [ @account ]) { FieldVoiceActivity.refresh!([ @account.id ]) }
          assert_events(details: [ @recording ]) { preview }
        end
      end
    end
  end

  private

  def preview(**attributes)
    FieldVoiceEnrolment.create!(account: @account, field_voice: @voice, field_recording_speaker: @speaker,
      start_generation: @voice.reload.print_generation, decision_generation: @speaker.decision_generation,
      sample_ms: 12_000, consent_text_version: FieldVoiceprints::CONSENT_TEXT_VERSION,
      expires_at: 1.hour.from_now, **attributes)
  end

  def attach_sample(enrolment)
    enrolment.sample.attach(io: StringIO.new("SECRET-SAMPLE"), filename: "sample.wav", content_type: "audio/wav")
  end

  def recognise(recording)
    recording.speakers.first.update!(recognised_voice: @voice, recognition_confidence: 90,
      recognition_print_generation: @voice.reload.print_generation, recognition_decision_generation: 0)
  end

  def presentation
    FieldItems.speaker_recognition_json(FieldRecordingSpeaker.find(@speaker.id), enabled: true)
  end

  def assert_events(details: [], rosters: [])
    expected = details.map { |recording| [ "FieldRecording:#{recording.to_param}", { action: "refresh", prop: "field_recording" } ] } +
      rosters.map { |account| [ "FieldVoiceActivity:#{account.to_param}", { action: "refresh" } ] }
    events = []
    subscriber = ->(*args) do
      payload = args.last
      if payload[:broadcasting].start_with?("FieldRecording:", "FieldVoiceActivity:")
        events << [ payload[:broadcasting], payload[:message] ]
      end
    end
    ActiveSupport::Notifications.subscribed(subscriber, "broadcast.action_cable") { yield }
    assert_equal expected.sort_by(&:first), events.sort_by(&:first)
  end

end
