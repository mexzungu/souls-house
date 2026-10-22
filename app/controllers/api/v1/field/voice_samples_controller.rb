module Api
  module V1
    module Field
      class VoiceSamplesController < BaseController

        include ApiHumanReach

        before_action :require_human_actor!
        require_api_feature_enabled :agents
        before_action :set_voice
        before_action :set_sample, except: %i[index create]

        rescue_from FieldVoiceprints::Limits::Reached do |error|
          render json: { error: error.message }, status: :conflict
        end
        rescue_from FieldVoiceSamples::Conflict do |error|
          render json: { error: error.message }, status: :conflict
        end
        rescue_from FieldVoiceSamples::Invalid do |error|
          render json: { error: error.message }, status: :unprocessable_entity
        end

        def index
          rows = samples.order(:id)
          page = [ params[:page].to_i, 1 ].max
          render json: { samples: rows.offset((page - 1) * 50).limit(50).map { |sample| present(sample) },
            page:, total: rows.count, pages: [ (rows.count / 50.0).ceil, 1 ].max,
            limits: { active: 20, pending: 20, minimum_confirmed: 2 } }
        end

        def show
          render json: { sample: present(@sample) }
        end

        def create
          unless params[:idempotency_key].is_a?(String) && params[:idempotency_key].present?
            return render json: { error: "Provide a stable idempotency_key for this upload." }, status: :unprocessable_entity
          end
          metadata = params.permit(:source_identifier, :source_sha256, :source_session,
            :start_ms, :end_ms, :recorded_at, :idempotency_key).to_h
          # A transcript in Field belongs to a recording; both names refer to
          # that account-scoped resource, never an arbitrary foreign row.
          if params[:recording_id].present? || params[:transcript_id].present?
            if params[:recording_id].present? && params[:transcript_id].present? && params[:recording_id] != params[:transcript_id]
              return render json: { error: "recording_id and transcript_id must identify the same recording." }, status: :unprocessable_entity
            end
            recording = @voice.account.field_recordings.kept.find_by!(
              id: FieldRecording.decode_id(params[:recording_id].presence || params[:transcript_id]))
            metadata["field_recording_id"] = recording.id
          end
          result = FieldVoiceSamples::Uploads.create_with_receipt!(voice: @voice, by: app_token_request? ? current_api_user : nil, file: params[:audio], metadata:)
          sample = result.sample
          FieldVoices::LearnUploadJob.queue!(sample)
          render json: { sample: present(sample), deduplicated: result.deduplicated },
            status: result.deduplicated ? :ok : :created
        rescue ActiveRecord::RecordInvalid, ArgumentError => error
          render json: { error: error.message }, status: :unprocessable_entity
        end

        def update
          if request.request_parameters.key?("voice_id")
            return render json: { error: "Change attribution separately from inclusion." }, status: :unprocessable_entity if params.key?(:included)
            target = @voice.account.field_voices.kept.find_by!(id: FieldVoice.decode_id(request.request_parameters["voice_id"]))
            if @sample.field_recording_speaker
              @voice.account.with_lock do
                speaker = @sample.field_recording_speaker
                speaker.field_recording.lock!
                @sample.reload
                unless params[:digest].present? && params[:digest] == @sample.source_digest &&
                    @sample.field_voice_id == @voice.id && @sample.source_current?
                  raise FieldVoiceSamples::Conflict, "This sample changed. Reload and retry."
                end
                FieldVoiceprints::Limits.pending!(target) unless target.id == @voice.id
                # Naming invalidates the old row. Carry the same embedded
                # audio forward as an unconfirmed candidate, never as a new
                # claim of human attribution or listening.
                replacement = FieldVoiceSample.new(account: @voice.account, field_voice: target,
                  field_recording_speaker: speaker, field_recording_id: @sample.field_recording_id,
                  speech_ms: @sample.speech_ms, profile: @sample.profile, eligible: false,
                  source_segments: @sample.source_segments, label_origin: app_token_request? ? "human" : "machine")
                replacement.vector = @sample.vector
                speaker.name_as!(target, by: current_api_user, source: app_token_request? ? "human" : "machine")
                replacement.source_digest = FieldVoiceSample.source_digest_for(speaker.reload, replacement.source_segments)
                replacement.save!
                @sample = replacement
              end
              return render json: { sample: present(@sample), message: "Source speaker corrected; this candidate requires review." }
            end
            @sample.reattribute!(voice: target, digest: params[:digest], by: app_token_request? ? current_api_user : nil)
            FieldVoices::LearnUploadJob.queue!(@sample.reload)
          else
            included = params[:included]
            unless [ true, false ].include?(included)
              return render json: { error: "Provide included: true or false." }, status: :unprocessable_entity
            end
            # An API key is machine provenance, even when owned by a person.
            # Re-inclusion of existing testimony is allowed; new testimony
            # requires the signed-in human app, never a body flag.
            if included && !@sample.manually_confirmed? && !app_token_request?
              return render json: { error: "Listen and confirm in Voices or the signed-in app. API keys cannot attest human listening." }, status: :forbidden
            end
            saved = if @sample.field_recording_speaker
              @sample.field_recording_speaker.review_sample!(sample: @sample, digest: params[:digest], by: current_api_user, included:, confirm: app_token_request?)
            else
              @sample.review!(digest: params[:digest], by: app_token_request? ? current_api_user : nil, included:)
            end
            return render json: { error: "This sample changed. Reload and listen again." }, status: :conflict unless saved
          end
          render json: { sample: present(@sample.reload) }
        end

        def destroy
          unless params[:digest].present? && params[:digest] == @sample.source_digest
            return render json: { error: "This sample changed. Reload and retry." }, status: :conflict
          end
          if @sample.field_recording_speaker
            speaker = @sample.field_recording_speaker
            recording = speaker.field_recording
            FieldVoiceprints::Locks.with(account: @voice.account, recording:, voices: [ @voice ]) do
              @sample.reload
              unless params[:digest] == @sample.source_digest && @sample.field_voice_id == @voice.id
                raise FieldVoiceSamples::Conflict, "This sample changed. Reload and retry."
              end
              speaker.reload.update!(sample_excluded: true, sample_review_generation: speaker.sample_review_generation + 1)
              @sample.update!(removed_at: Time.current, eligible: false)
              FieldVoiceprints::Learning.rebuild!(@voice)
            end
          else
            @sample.remove!(digest: params[:digest], by: current_api_user)
          end
          head :no_content
        end

        def audio
          unless params[:digest].present? && params[:digest] == @sample.source_digest && @sample.source_current?
            return head :conflict
          end
          bytes = if @sample.field_recording_speaker
            FieldVoiceprints::Sample.cut(@sample.field_recording_speaker.field_recording, @sample.source_segments) { |path| File.binread(path) }
          else
            @sample.audio.download
          end
          response.headers["Cache-Control"] = "private, no-store"
          send_data bytes, type: "audio/wav", disposition: "attachment", filename: "voice-sample.wav"
        rescue FieldVoiceprints::Sample::Refused, ActiveStorage::FileNotFoundError
          head :not_found
        end

        private

        def set_voice
          if request.path_parameters[:voice_id].present?
            @voice = find_human_record!(FieldVoice.kept, request.path_parameters[:voice_id])
          else
            @sample = find_human_record!(FieldVoiceSample.where(removed_at: nil), params[:id])
            @voice = @sample.field_voice
            raise ActiveRecord::RecordNotFound unless @voice.kept?
          end
        end

        def samples
          @voice.samples.where(removed_at: nil)
        end

        def set_sample
          @sample = samples.find_by!(id: FieldVoiceSample.decode_id(params[:id]))
        end

        def present(sample)
          FieldVoiceSamples::Presentation.row(sample).merge(
            audio_url: (audio_api_v1_field_voice_sample_path(sample.field_voice, sample, digest: sample.source_digest) if sample.source_current?))
        end

      end
    end
  end
end
