<script>
  // What a plan includes, from the catalogue (Billing::Tier#features). Shared by
  // /pricing and the Billing tab so the two can't describe a plan differently.
  let { features, class: className = '' } = $props();
</script>

<ul class="space-y-1.5 {className}">
  <li>
    Its own machine: {features.vcpus} vCPUs, {features.ram_gb} GB memory, {features.disk_gb} GB total disk (the system uses
    some of it)
  </li>
  <li>Up to ${features.allowance_usd} a month of the house model (Claude Haiku 5.5 or DeepSeek V4.1 Flash)</li>
  <li>{features.transcription_hours} hours of recording transcription a month</li>
  <li>Off-site backups of their home, up to {features.backup_gb} GB stored</li>
  {#if features.swarm_searches > 0}
    <li>Swarm search across your Field, {features.swarm_searches} searches a month</li>
  {/if}
</ul>
