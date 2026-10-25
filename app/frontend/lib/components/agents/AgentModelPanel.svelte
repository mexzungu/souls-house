<script>
  import HouseAllowance from '$lib/components/agents/house-allowance.svelte';
  import { Label } from '$lib/components/shadcn/label';
  import * as Select from '$lib/components/shadcn/select/index.js';
  import { findModel } from '$lib/agent-models';
  import AgentModelSelect from '$lib/components/agents/AgentModelSelect.svelte';
  import { siteName } from '$lib/branding';

  let {
    form,
    groupedModels = {},
    selectedModel = $bindable(),
    runtimeManaged = false,
    houseAllowance = null,
    children,
  } = $props();

  let reasoning = $derived(findModel(groupedModels, selectedModel)?.reasoning || null);
  let effortOptions = $derived(
    reasoning
      ? [
          {
            value: 'default',
            label: `Provider default (${reasoning.options.find((option) => option.value === reasoning.default)?.label || reasoning.default})`,
            description: 'Use the default reasoning setting advertised for this model.',
          },
          ...reasoning.options,
        ]
      : []
  );

  let selectedEffort = $derived(
    effortOptions.find((option) => option.value === $form.agent.reasoning_effort) || effortOptions[0]
  );

  $effect(() => {
    if (!reasoning || !effortOptions.some((option) => option.value === $form.agent.reasoning_effort)) {
      $form.agent.reasoning_effort = 'default';
    }
  });
</script>

<!-- One card: the model, its effort as a sub-setting, and whatever the
     settings page nests beneath them (the additional conversation models). -->
<section class="rounded-lg border p-5 space-y-5" aria-labelledby="ai-model-heading">
  <div class="space-y-4">
    <div>
      <h2 id="ai-model-heading" class="text-lg font-semibold">AI model</h2>
      <p class="text-sm text-muted-foreground">
        {runtimeManaged
          ? `The model ${$siteName} sends to this resident's runtime on each trigger. Changes apply from the next trigger.`
          : 'Choose which AI model powers this resident'}
      </p>
    </div>
    <AgentModelSelect {groupedModels} bind:value={selectedModel} />
    <HouseAllowance {selectedModel} allowance={houseAllowance} />
    {#if $form.errors?.model_id}<p class="text-sm text-destructive">{$form.errors.model_id}</p>{/if}
  </div>

  <div class="ml-1 border-l-2 pl-4 space-y-2" data-testid="model-effort">
    {#if reasoning}
      <Label for="reasoning_effort">{reasoning.label}</Label>
      <Select.Root
        type="single"
        value={$form.agent.reasoning_effort}
        onValueChange={(value) => ($form.agent.reasoning_effort = value)}>
        <Select.Trigger id="reasoning_effort" class="w-full max-w-xs">{selectedEffort.label}</Select.Trigger>
        <Select.Content sideOffset={4}>
          {#each effortOptions as option}
            <Select.Item value={option.value} label={option.label}>{option.label}</Select.Item>
          {/each}
        </Select.Content>
      </Select.Root>
      <p class="text-xs text-muted-foreground">{selectedEffort.description}</p>
    {:else}
      <p class="text-sm font-medium">Reasoning</p>
      <p class="text-xs text-muted-foreground">This model has no reasoning setting to choose; it uses its default.</p>
    {/if}
  </div>

  {@render children?.()}
</section>
