<script>
  import { Microphone, MicrophoneSlash, Spinner } from 'phosphor-svelte';
  import { onDestroy, onMount } from 'svelte';
  import { holdForRecording } from '$lib/recording-guard';
  import { clearRecovery, expiryLabel, loadRecovery, readTranscription, saveRecovery } from '$lib/voice-note-recovery';

  const MIN_AUDIO_BYTES = 1000;

  let { disabled = false, accountId, chatId, userId, onsuccess, onerror } = $props();

  let state = $state('idle');

  let mediaRecorder = null;
  let audioChunks = [];
  // Held from the moment recording starts until the transcript (or an error) is back, so a
  // background refresh after a deploy cannot reload the page and lose the audio.
  let releaseHold = null;

  function release() {
    releaseHold?.();
    releaseHold = null;
  }

  // A recording whose transcription failed (#453): its bytes (kept in the tab until it is
  // transcribed or discarded), the server's reference if it has one, and what we can honestly
  // say about where it is ('saved' | 'unconfirmed' | 'unsaved' | 'gone').
  let failure = $state(null);
  let failureHold = null;
  const scope = () => ({ userId, accountId, chatId });

  // Warn before leaving while a reload would lose the recording: it is only in this tab, or the
  // server has it but this browser could not remember where. Called synchronously after every
  // change to `failure`, before the recording's own hold is let go, so there is no gap.
  function syncFailureHold() {
    const atRisk = !!failure?.blob && !(failure.saved === 'saved' && failure.persisted);
    if (atRisk && !failureHold) failureHold = holdForRecording();
    if (!atRisk && failureHold) {
      failureHold();
      failureHold = null;
    }
  }

  onMount(() => {
    const recovered = userId ? loadRecovery(scope()) : null;
    if (!recovered) return;
    if (recovered.expired) {
      clearRecovery(scope());
      failure = {
        saved: 'gone',
        error: 'A voice note that failed to transcribe has expired and is no longer available.',
      };
    } else {
      failure = { ...recovered, saved: 'saved', persisted: true, retryable: true, recovered: true };
    }
    state = 'failed';
  });

  onDestroy(() => {
    release();
    failureHold?.();
    failureHold = null;
  });

  const isRecording = $derived(state === 'recording');
  const isTranscribing = $derived(state === 'transcribing');
  const isFailed = $derived(state === 'failed');

  async function toggleRecording() {
    if (isRecording) {
      stopRecording();
    } else if (state === 'idle') {
      await startRecording();
    }
  }

  async function startRecording() {
    try {
      const stream = await navigator.mediaDevices.getUserMedia({ audio: true });

      const mimeType = MediaRecorder.isTypeSupported('audio/webm;codecs=opus')
        ? 'audio/webm;codecs=opus'
        : MediaRecorder.isTypeSupported('audio/webm')
          ? 'audio/webm'
          : MediaRecorder.isTypeSupported('audio/mp4')
            ? 'audio/mp4'
            : '';

      const options = mimeType ? { mimeType } : {};
      const recorder = new MediaRecorder(stream, options);
      audioChunks = [];

      recorder.ondataavailable = (event) => {
        if (event.data.size > 0) {
          audioChunks.push(event.data);
        }
      };

      recorder.onstop = async () => {
        stream.getTracks().forEach((track) => track.stop());

        if (audioChunks.length === 0) {
          state = 'idle';
          release();
          return;
        }

        const actualMimeType = recorder.mimeType || 'audio/webm';
        const blob = new Blob(audioChunks, { type: actualMimeType });
        audioChunks = [];

        if (blob.size < MIN_AUDIO_BYTES) {
          state = 'idle';
          release();
          onerror?.('Recording too short');
          return;
        }

        await transcribe(blob, actualMimeType);
      };

      recorder.start();
      mediaRecorder = recorder;
      state = 'recording';
      releaseHold = holdForRecording();
    } catch (err) {
      state = 'idle';
      release();
      if (err.name === 'NotAllowedError') {
        onerror?.('Microphone access denied. Please allow microphone access in your browser settings.');
      } else if (err.name === 'NotFoundError') {
        onerror?.('No microphone found. Please connect a microphone and try again.');
      } else {
        onerror?.('Could not start recording');
      }
    }
  }

  function stopRecording() {
    if (mediaRecorder && mediaRecorder.state === 'recording') {
      mediaRecorder.stop();
      state = 'transcribing';
    }
  }

  function transcriptionPath() {
    return chatId
      ? `/accounts/${accountId}/chats/${chatId}/transcription`
      : `/accounts/${accountId}/chats/transcription`;
  }

  function request(method, formData) {
    return fetch(transcriptionPath(), {
      method,
      headers: {
        'X-CSRF-Token': document.querySelector('meta[name="csrf-token"]')?.content,
        Accept: 'application/json',
      },
      credentials: 'same-origin',
      body: formData,
    }).catch(() => null);
  }

  function uploadForm(blob, mimeType) {
    const ext = mimeType.includes('mp4') ? 'mp4' : 'webm';
    const formData = new FormData();
    formData.append('audio', blob, `recording.${ext}`);
    return formData;
  }

  function signedIdForm(signedId) {
    const formData = new FormData();
    formData.append('audio_signed_id', signedId);
    return formData;
  }

  function succeed(result, { retry }) {
    clearRecovery(scope());
    const handover = holdForRecording({ warn: false });
    failure = null;
    syncFailureHold();
    state = 'idle';
    // Hand over without a gap: a quiet hold covers the moment between dropping the
    // recording's warning hold (so the composer's own send is not met with "discard the
    // recording?") and the composer taking its hold for the send.
    release();
    try {
      onsuccess?.(result.text, result.signedId, { retry });
    } finally {
      handover();
    }
  }

  // What the recording is after a failed attempt. The bytes stay in the tab whatever the
  // server says, until a transcription succeeds or the person discards it.
  function fail(result, bytes) {
    const blob = bytes?.blob ?? failure?.blob ?? null;
    const mimeType = bytes?.mimeType ?? failure?.mimeType ?? null;

    if (result.saved === 'saved' && (result.signedId || failure?.signedId)) {
      const signedId = result.signedId || failure.signedId;
      const expiresAt = result.expiresAt ?? failure?.expiresAt ?? null;
      const persisted = userId ? saveRecovery(scope(), { signedId, error: result.error, expiresAt }) : false;
      failure = {
        blob,
        mimeType,
        signedId,
        expiresAt,
        persisted,
        saved: 'saved',
        error: result.error,
        retryable: result.retryable !== false,
      };
    } else if (result.saved === 'gone') {
      clearRecovery(scope());
      failure = blob
        ? {
            blob,
            mimeType,
            saved: 'unsaved',
            retryable: true,
            error: `${result.error} It is still in this tab; Retry uploads it again.`,
          }
        : { saved: 'gone', error: result.error };
    } else {
      failure = {
        blob,
        mimeType,
        saved: result.saved,
        error: result.error,
        retryable: result.retryable !== false && !!blob,
      };
    }
    syncFailureHold();
    state = 'failed';
    release();
  }

  async function transcribe(blob, mimeType) {
    state = 'transcribing';
    const result = await readTranscription(await request('POST', uploadForm(blob, mimeType)));
    if (result.ok) succeed(result, { retry: false });
    else fail(result, { blob, mimeType });
  }

  async function retry() {
    if (!failure || failure.busy) return;
    failure.busy = 'retry';
    failure.discardError = null;
    const retrying = !!failure.signedId;
    const response = retrying
      ? await request('POST', signedIdForm(failure.signedId))
      : await request('POST', uploadForm(failure.blob, failure.mimeType));
    const result = await readTranscription(response, { retrying });
    if (result.ok) succeed(result, { retry: true });
    else fail(result);
  }

  async function discard() {
    if (!failure || failure.busy) return;
    if (failure.signedId) {
      failure.busy = 'discard';
      failure.discardError = null;
      const response = await request('DELETE', signedIdForm(failure.signedId));
      // 404: already gone, which is what was asked for.
      if (!response || !(response.ok || response.status === 404)) {
        failure.busy = null;
        failure.discardError =
          response?.status === 409
            ? 'That recording has already been sent, so it was not deleted.'
            : 'Could not delete the recording. It is still saved; try again.';
        return;
      }
    }
    clearRecovery(scope());
    failure = null;
    syncFailureHold();
    state = 'idle';
  }

  function dismiss() {
    clearRecovery(scope());
    failure = null;
    syncFailureHold();
    state = 'idle';
  }
</script>

<div class="relative">
  <button
    type="button"
    onclick={toggleRecording}
    disabled={disabled || isTranscribing || isFailed}
    class="h-10 w-10 p-0 inline-flex items-center justify-center rounded-md transition-colors
           {isRecording
      ? 'bg-red-500 text-white hover:bg-red-600 animate-pulse'
      : 'hover:bg-accent hover:text-accent-foreground'}
           disabled:pointer-events-none disabled:opacity-50"
    title={isRecording
      ? 'Stop recording'
      : isTranscribing
        ? 'Transcribing...'
        : isFailed
          ? 'Retry or discard the voice note first'
          : 'Record voice message'}>
    {#if isTranscribing}
      <Spinner size={18} class="animate-spin" />
    {:else if isRecording}
      <MicrophoneSlash size={18} />
    {:else}
      <Microphone size={18} />
    {/if}
  </button>

  {#if failure}
    <div
      role="alert"
      data-testid="voice-note-recovery"
      data-saved={failure.saved}
      class="absolute bottom-full right-0 z-20 mb-2 w-72 max-w-[calc(100vw-2rem)] rounded-md border border-border bg-background p-3 text-sm shadow-lg">
      {#if failure.saved === 'gone'}
        <p>{failure.error}</p>
        <div class="mt-2 flex justify-end">
          <button type="button" class="rounded-md px-2 py-1 hover:bg-accent" onclick={dismiss}>Dismiss</button>
        </div>
      {:else}
        <p class="font-medium">Voice note not transcribed</p>
        <p class="mt-1 text-muted-foreground">{failure.error}</p>
        {#if failure.saved === 'saved'}
          <p class="mt-1 text-muted-foreground">
            Your recording is saved{failure.expiresAt ? ` until ${expiryLabel(failure.expiresAt)}` : ''}.
            {#if !failure.persisted}
              This browser could not remember it, so keep this tab open.
            {/if}
          </p>
        {:else if failure.saved === 'unsaved'}
          <p class="mt-1 text-muted-foreground">Not saved yet. Keep this tab open.</p>
        {/if}
        {#if failure.discardError}
          <p class="mt-1 text-destructive">{failure.discardError}</p>
        {/if}
        <div class="mt-2 flex justify-end gap-2">
          <button
            type="button"
            class="rounded-md px-2 py-1 hover:bg-accent disabled:opacity-50"
            disabled={!!failure.busy}
            onclick={discard}>
            {failure.busy === 'discard' ? 'Discarding…' : 'Discard'}
          </button>
          {#if failure.retryable}
            <button
              type="button"
              class="rounded-md bg-primary px-2 py-1 text-primary-foreground hover:bg-primary/90 disabled:opacity-50"
              disabled={!!failure.busy || disabled}
              onclick={retry}>
              {failure.busy === 'retry' ? 'Retrying…' : 'Retry transcription'}
            </button>
          {/if}
        </div>
      {/if}
    </div>
  {/if}
</div>
