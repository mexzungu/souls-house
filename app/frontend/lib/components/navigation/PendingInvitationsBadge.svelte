<script>
  // An envelope with a count: accounts that have invited you and are waiting
  // for you to accept. Black like the expired-subscriptions count; it is a
  // door held open, not unread mail.
  import { EnvelopeSimple } from 'phosphor-svelte';

  let { count = 0 } = $props();
  const label = $derived(`${count} pending ${count === 1 ? 'invitation' : 'invitations'}`);
</script>

{#if count > 0}
  <span
    class="inline-flex h-5 shrink-0 items-center gap-0.5 rounded-full bg-neutral-950 px-1.5 text-xs font-semibold text-white dark:bg-white dark:text-neutral-950"
    title={label}
    aria-label={label}
    data-testid="pending-invitations-badge">
    <EnvelopeSimple class="size-3.5" weight="bold" aria-hidden="true" />
    {count > 99 ? '99+' : count}
  </span>
{/if}
