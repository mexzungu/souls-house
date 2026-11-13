<script>
  import { Input } from '$lib/components/shadcn/input';
  import { Label } from '$lib/components/shadcn/label';
  let { form } = $props();
</script>

  <div class="space-y-5 rounded-lg border p-5">
    <div class="space-y-1">
      <p class="text-sm font-medium">Button taps for a resident that runs elsewhere</p>
      <p class="text-xs text-muted-foreground">
        If this bot posts cards with inline buttons from outside the house, the house forwards each tap
        (the button's data and the tapping user's id) to this address, signed with the secret, and shows
        the reply. Leave both blank and taps are ignored, as before.
      </p>
    </div>
    <div class="space-y-2">
      <Label for="telegram_callback_forward_url">Forward taps to</Label>
      <Input
        id="telegram_callback_forward_url"
        type="url"
        bind:value={$form.agent.telegram_callback_forward_url}
        placeholder="https://example.com/telegram/callback" />
    </div>
    <div class="space-y-2">
      <Label for="telegram_callback_forward_secret">Forward secret</Label>
      <Input
        id="telegram_callback_forward_secret"
        type="password"
        bind:value={$form.agent.telegram_callback_forward_secret}
        placeholder="Leave blank to keep the current secret" />
      <p class="text-xs text-muted-foreground">Sent as the X-Lead-Callback-Secret header. Encrypted when stored, never shown again.</p>
    </div>
