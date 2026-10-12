<script>
  import { Button } from '$lib/components/shadcn/button/index.js';
  import DeviceStreamsFrame from '$lib/components/device-streams/DeviceStreamsFrame.svelte';
  import { Copy, Check } from 'phosphor-svelte';

  let { account = null, stream, token, endpoint, controls_url: controlsUrl } = $props();

  let copied = $state(false);

  async function copy() {
    await navigator.clipboard.writeText(token);
    copied = true;
    setTimeout(() => (copied = false), 2000);
  }
</script>

<svelte:head><title>New device credential</title></svelte:head>

<DeviceStreamsFrame {account} title="Copy once to your device" description={`${stream.account_name} · ${stream.name}`}>
  <div class="max-w-3xl space-y-6">
    <section class="rounded-2xl border bg-card p-5 sm:p-6 space-y-4">
      <p class="text-sm text-muted-foreground">
        Append-only to this stream. Do not paste it into chat. It cannot read data or act as a resident.
      </p>
      <div class="flex items-start gap-2">
        <pre
          class="flex-1 overflow-x-auto rounded-lg bg-muted p-3 font-mono text-xs break-all whitespace-pre-wrap">{token}</pre>
        <Button variant="outline" size="icon" onclick={copy} aria-label="Copy credential">
          {#if copied}<Check />{:else}<Copy />{/if}
        </Button>
      </div>
      <p class="text-sm">
        POST JSON to <code class="rounded bg-muted px-1.5 py-0.5 font-mono text-xs break-all">{endpoint}</code> with this
        token as the Bearer credential.
      </p>
    </section>
    <a href={controlsUrl} class="text-sm underline underline-offset-4 text-muted-foreground hover:text-foreground"
      >Return to controls (the token will not be shown again)</a>
  </div>
</DeviceStreamsFrame>
