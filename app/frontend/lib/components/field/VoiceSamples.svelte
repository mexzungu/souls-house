<script>
  // A voice's fingerprint samples as a compact review list: play, accept,
  // reject. Each sample is the exact montage that was embedded (several source
  // spans joined), so Accept stays off until it has been played to the end.
  // Namings with no usable sample are a count, listed only on request.
  // Accept and reject show at once: the row moves to the end, marked saving,
  // and the list refreshes behind it, so the next sample can be played
  // straight away. A failed save puts the row back with the reason.
  // A sample from a long recording takes seconds to cut, so the next few are
  // cut ahead (warm), and a row shows it is loading until sound starts. A
  // play interrupted by a click or a refresh is not an error.
  import { untrack } from 'svelte';
  import { Button } from '$lib/components/shadcn/button/index.js';
  import VoiceSampleRow from './VoiceSampleRow.svelte';
  import OtherNamings from './OtherNamings.svelte';
  import { STATES } from './voice-sample-format.js';
  import { orderedRows, shownCounts, stillPending } from './voice-sample-pending.js';

  let { base, name, version = '', onChanged = () => {} } = $props();

  let result = $state(null);
  let loading = $state(false);
  let busy = $state(null);
  let error = $state('');
  let heard = $state({});
  let loadedFor = $state(null);

  let audio = $state(null);
  // What the player actually loaded: the row and the exact digest. A row can
  // be replaced by a refresh while it plays; completion counts only for the
  // digest that was heard (Mira's review of #488).
  let playing = $state(null);
  const playingId = $derived(playing?.id ?? null);
  let page = $state(1);
  let paused = $state(true);
  // The row whose audio has been asked for and has not started sounding.
  let loadingId = $state(null);
  // id|digest -> when it was last asked to be cut ahead. The server keeps a cut
  // for ten minutes, so ask again after five.
  let warmed = new Map();
  let progress = $state({});

  // Reviews shown before the server has answered (voice-sample-pending.js).
  let pending = $state({});
  let loadSeq = 0;
  let appliedSeq = 0;
  // The list request in flight, for one voice: { base, promise }.
  let inFlight = null;
  let again = null;

  const headers = () => ({
    Accept: 'application/json',
    'Content-Type': 'application/json',
    'X-CSRF-Token': document.querySelector('meta[name="csrf-token"]')?.content || '',
  });

  // One list request at a time per voice; asks made meanwhile become one more
  // after it. Another voice's request never holds this one up: it is simply
  // superseded, and its completion touches nothing (Mira's review of #497).
  function load(nextPage = page) {
    if (inFlight?.base === base) {
      again = nextPage;
      return inFlight.promise;
    }
    const request = { base };
    again = null;
    inFlight = request;
    request.promise = fetchList(nextPage).finally(() => {
      if (inFlight !== request) return;
      inFlight = null;
      if (again != null) {
        const next = again;
        again = null;
        load(next);
      }
    });
    return request.promise;
  }

  async function fetchList(nextPage) {
    const url = base;
    const seq = ++loadSeq;
    loading = true;
    try {
      const response = await fetch(`${url}/samples?page=${nextPage}`, { headers: { Accept: 'application/json' } });
      if (!response.ok) throw new Error('Samples could not be loaded. Please try again.');
      const body = await response.json();
      if (url !== base || seq < appliedSeq) return;
      appliedSeq = seq;
      result = body;
      page = body.page || 1;
      pending = stillPending(pending, seq);
      // The playing row changed under the player (rebuilt, or gone): stop,
      // and forget its progress, so nothing heard before carries over.
      const row = playing && body.samples.find((sample) => sample.id === playing.id);
      if (playing && (!row || row.digest !== playing.digest || row.audio_url !== playing.url)) {
        const { id } = playing;
        stop();
        const { [id]: _dropped, ...rest } = progress;
        progress = rest;
      }
    } catch (failure) {
      if (url === base) error = failure.message;
    } finally {
      if (url === base) loading = false;
    }
  }

  // A different voice, or a roster change that touched this one: start again.
  $effect(() => {
    const key = `${base}|${version}`;
    untrack(() => {
      if (key === loadedFor) return;
      const sameVoice = loadedFor?.split('|')[0] === base;
      loadedFor = key;
      if (!sameVoice) {
        result = null;
        heard = {};
        progress = {};
        pending = {};
        warmed = new Map();
        page = 1;
        stop();
      }
      load();
    });
  });

  // Rebuilds run in the background; check again while any is pending.
  $effect(() => {
    if (!result?.samples?.some((sample) => sample.state === 'preparing')) return;
    const timer = setTimeout(() => untrack(load), 4000);
    return () => clearTimeout(timer);
  });

  function stop() {
    if (playing) audio?.pause();
    playing = null;
    paused = true;
    loadingId = null;
  }

  // Ask the server to cut the next few playable samples after `from` (or the
  // top of the list), so they start at once when played. Fire and forget.
  function warmAhead(from = null) {
    const list = rows;
    const start = from == null ? 0 : list.findIndex((row) => row.id === from) + 1;
    const ids = list
      .slice(Math.max(start, 0))
      .filter((row) => row.audio_url && !String(row.id).startsWith('upload-') && !heardIt(row))
      .filter((row) => row.state === 'review' || (row.state === 'removed' && !result?.full))
      .filter((row) => !(Date.now() - (warmed.get(`${row.id}|${row.digest}`) ?? -Infinity) < 5 * 60_000))
      .slice(0, WARM_AHEAD);
    if (!ids.length) return;
    ids.forEach((row) => warmed.set(`${row.id}|${row.digest}`, Date.now()));
    fetch(`${base}/samples/warm`, {
      method: 'POST',
      headers: headers(),
      body: JSON.stringify({ ids: ids.map((row) => row.id) }),
    }).catch(() => {});
  }

  // play() is refused with AbortError when a pause or a new source interrupts
  // it; that is the person (or a refresh) changing their mind, not a failure.
  function playFailed(failure) {
    if (failure?.name === 'AbortError') return;
    loadingId = null;
    error = 'This audio could not be played. Check the source recording, then try again.';
  }

  function toggle(sample) {
    if (!audio || !sample.audio_url) return;
    error = '';
    if (playing?.id === sample.id && playing.digest === sample.digest && playing.url === sample.audio_url) {
      if (audio.paused) {
        loadingId = sample.id;
        audio.play().catch(playFailed);
      } else audio.pause();
      return;
    }
    playing = { id: sample.id, digest: sample.digest, url: sample.audio_url };
    loadingId = sample.id;
    audio.src = sample.audio_url;
    audio.currentTime = 0;
    audio.play().catch(playFailed);
    warmAhead(sample.id);
  }

  function tick() {
    if (!playingId || !audio?.duration) return;
    progress = { ...progress, [playingId]: audio.currentTime / audio.duration };
  }

  function ended() {
    if (playing) {
      heard = { ...heard, [playing.id]: playing.digest };
      progress = { ...progress, [playing.id]: 1 };
    }
    paused = true;
    loadingId = null;
  }

  async function save(path, method, body) {
    const response = await fetch(path, { method, headers: headers(), body: body && JSON.stringify(body) });
    if (!response.ok) {
      const reply = await response.json().catch(() => ({}));
      throw new Error(reply.error || 'That change could not be saved. Refresh and try again.');
    }
  }

  // Shown at once; nothing else waits for the server.
  async function review(sample, included) {
    const url = base;
    error = '';
    pending = { ...pending, [sample.id]: { included, settled: null } };
    try {
      await save(`${url}/samples/${sample.id}`, 'PATCH', { included, digest: sample.digest });
      if (url !== base) return;
      if (pending[sample.id]) pending = { ...pending, [sample.id]: { included, settled: loadSeq } };
      load();
      onChanged();
    } catch (failure) {
      if (url !== base) return;
      const { [sample.id]: _failed, ...rest } = pending;
      pending = rest;
      error = failure.message;
      load();
    }
  }

  async function prepareAll() {
    busy = 'all';
    error = '';
    try {
      await save(`${base}/samples/prepare`, 'POST');
      await load();
      onChanged();
    } catch (failure) {
      error = failure.message;
    } finally {
      busy = null;
    }
  }

  const rows = $derived(orderedRows(result?.samples, pending));
  const WARM_AHEAD = 8;

  // Whenever the list (re)loads, have the first samples cut before they're asked for.
  $effect(() => {
    if (!result) return;
    untrack(() => warmAhead(playing?.id ?? null));
  });

  const heardIt = (sample) => heard[sample.id] === sample.digest;
  // Accepting says "I heard all of this and it is only them". A sample
  // confirmed earlier and later removed can come back without replaying.
  // With twenty included, nothing more is added until one is rejected (an
  // included sample can still be confirmed).
  const canAccept = (sample) =>
    (!result?.full || sample.included) &&
    sample.source_current &&
    (sample.state === 'review' || sample.state === 'removed') &&
    (heardIt(sample) || (sample.state === 'removed' && sample.confirmed));

  const counts = $derived(shownCounts(result, pending));
</script>

<!-- One shared player: only one sample sounds at a time. -->
<audio
  bind:this={audio}
  preload="none"
  class="hidden"
  data-testid="sample-audio"
  onplay={() => (paused = false)}
  onplaying={() => (loadingId = null)}
  onpause={() => {
    paused = true;
    loadingId = null;
  }}
  ontimeupdate={tick}
  onended={ended}
  onerror={() => {
    // A source swapped mid-load reports MEDIA_ERR_ABORTED; only a real failure is shown.
    if (!playingId || audio?.error?.code === 1) return;
    loadingId = null;
    error = 'This audio could not be played. Check the source recording, then try again.';
  }}></audio>

<section class="space-y-3" data-testid="voice-samples">
  {#if error}<p role="alert" class="text-sm text-destructive">{error}</p>{/if}
  {#if !result && loading}<p class="text-sm text-muted-foreground">Loading samples…</p>{/if}

  {#if result}
    <div class="flex flex-wrap items-center justify-between gap-2">
      <div class="text-sm">
        <p data-testid="voice-print-state">{result.print}</p>
        {#if result.learning !== 'Learning enabled'}<p class="text-muted-foreground">{result.learning}</p>{/if}
      </div>
      {#if result.preparable > 0}
        <Button size="sm" disabled={busy != null} onclick={prepareAll} data-testid="voice-prepare">
          Prepare {result.preparable}
          {result.preparable === 1 ? 'sample' : 'samples'} for listening
        </Button>
      {/if}
    </div>

    {#if result.samples.length === 0}
      <p class="text-sm text-muted-foreground">No fingerprint samples yet.</p>
    {:else}
      <p class="text-xs text-muted-foreground">
        {result.total}
        {result.total === 1 ? 'sample' : 'samples'}
        {#each Object.keys(STATES) as state (state)}
          {#if counts[state]}<span> · {counts[state]} {STATES[state].label.toLowerCase()}</span>{/if}
        {/each}.
        {#if result.full}
          Twenty samples are included, which is as many as a fingerprint uses, so no new ones are offered. Reject one if
          it is wrong, and candidates are offered again.
        {:else}
          Accept after playing a sample to the end, if it is only {name} throughout. Wrong person or mixed voices: reject
          it, then correct the speaker in the recording.
        {/if}
      </p>
      <ul class="divide-y rounded-md border" data-testid="voice-sample-list">
        {#each rows as sample (sample.id)}
          <VoiceSampleRow
            {sample}
            {name}
            playing={playingId === sample.id && playing.digest === sample.digest && !paused}
            progress={progress[sample.id] ?? null}
            loading={loadingId === sample.id && playingId === sample.id}
            busy={busy != null || sample.saving}
            acceptable={canAccept(sample)}
            full={result.full}
            onToggle={() => toggle(sample)}
            onReview={(included) => review(sample, included)} />
        {/each}
      </ul>
      {#if result.pages > 1}
        <div class="flex items-center gap-2 text-xs" data-testid="voice-sample-pages">
          <Button size="sm" variant="ghost" disabled={loading || page <= 1} onclick={() => load(page - 1)}
            >Previous</Button>
          <span>Page {page} of {result.pages}</span>
          <Button size="sm" variant="ghost" disabled={loading || page >= result.pages} onclick={() => load(page + 1)}
            >Next</Button>
        </div>
      {/if}
    {/if}

    {#if result.other_namings > 0}
      {#key base}<OtherNamings {base} count={result.other_namings} />{/key}
    {/if}
  {/if}
</section>
