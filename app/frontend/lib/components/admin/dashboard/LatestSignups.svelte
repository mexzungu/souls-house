<script>
  import { formatCount, shortDateTime, timeAgo } from './format.js';

  let { signups = [], generatedAt } = $props();

  // Busy this week, quiet but alive this month, or silent.
  function residentTone(resident) {
    if (!resident.active) return 'bg-muted-foreground/40';
    if (resident.turns_7d > 0) return 'bg-teal-500';
    if (resident.turns_30d > 0) return 'bg-amber-400';
    return 'bg-rose-400';
  }

  function residentState(resident) {
    if (!resident.active) return 'archived';
    if (resident.paused) return 'paused';
    return null;
  }
</script>

<div class="rounded-xl border bg-card p-5" data-testid="latest-signups">
  <div class="mb-3 flex items-baseline justify-between">
    <h2 class="font-medium">Latest sign-ups</h2>
    <span class="text-xs text-muted-foreground">newest {signups.length} · turns 7d / 30d per resident</span>
  </div>
  {#if signups.length === 0}
    <p class="text-sm text-muted-foreground">Nobody has signed up yet.</p>
  {:else}
    <div class="overflow-x-auto">
      <table class="w-full text-sm">
        <thead class="text-left text-xs text-muted-foreground">
          <tr class="border-b">
            <th class="py-2 pr-4 font-normal">Who</th>
            <th class="py-2 pr-4 font-normal">Signed up</th>
            <th class="py-2 pr-4 font-normal">Their messages</th>
            <th class="py-2 font-normal">Residents</th>
          </tr>
        </thead>
        <tbody>
          {#each signups as signup}
            <tr class="border-b last:border-0 align-top" data-testid="latest-signup">
              <td class="py-2.5 pr-4 min-w-0">
                <div class="font-medium break-all">{signup.email}</div>
                <div class="flex flex-wrap items-center gap-1.5 text-xs text-muted-foreground">
                  {#if signup.name}<span>{signup.name}</span>{/if}
                  {#each signup.accounts as account}
                    <a class="underline-offset-2 hover:underline" href={`/admin/accounts?account_id=${account.id}`}
                      >{account.name}{account.role !== 'owner' ? ` (${account.role})` : ''}</a>
                  {/each}
                  {#if !signup.confirmed}
                    <span
                      class="rounded-full bg-amber-100 px-1.5 text-amber-800 dark:bg-amber-900/40 dark:text-amber-300"
                      >unconfirmed</span>
                  {/if}
                  {#if signup.founding}
                    <span class="rounded-full bg-muted px-1.5">founding</span>
                  {/if}
                </div>
              </td>
              <td class="py-2.5 pr-4 whitespace-nowrap" title={shortDateTime(signup.signed_up_at)}>
                {timeAgo(signup.signed_up_at, generatedAt)}
              </td>
              <td class="py-2.5 pr-4 whitespace-nowrap tabular-nums">
                {#if signup.messages_total}
                  {formatCount(signup.messages_7d)} this week
                  <div class="text-xs text-muted-foreground">
                    {formatCount(signup.messages_total)} total · last {timeAgo(signup.last_message_at, generatedAt)}
                  </div>
                {:else}
                  <span class="text-muted-foreground">none yet</span>
                {/if}
              </td>
              <td class="py-2.5">
                {#if signup.residents.length === 0}
                  <span class="text-muted-foreground">no resident yet</span>
                {:else}
                  <ul class="space-y-1">
                    {#each signup.residents as resident}
                      <li class="flex flex-wrap items-center gap-x-2 gap-y-0.5" data-testid="latest-signup-resident">
                        <span class={`size-2 shrink-0 rounded-full ${residentTone(resident)}`}></span>
                        <span class="font-medium">{resident.name}</span>
                        {#if residentState(resident)}
                          <span class="text-xs text-muted-foreground">({residentState(resident)})</span>
                        {/if}
                        <span
                          class="text-xs tabular-nums text-muted-foreground"
                          title={`${resident.conversation_turns_30d} conversation turns in 30 days, ${resident.turns_total} turns ever; made ${shortDateTime(resident.created_at)}`}>
                          {formatCount(resident.turns_7d)} / {formatCount(resident.turns_30d)} turns{resident.last_turn_at
                            ? ` · last ${timeAgo(resident.last_turn_at, generatedAt)}`
                            : ' · never run'}
                        </span>
                      </li>
                    {/each}
                  </ul>
                {/if}
              </td>
            </tr>
          {/each}
        </tbody>
      </table>
    </div>
  {/if}
</div>
