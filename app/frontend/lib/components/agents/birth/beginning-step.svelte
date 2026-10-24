<script>
  import SeedLoop from './seed-loop.svelte';
  import { CardContent } from '$lib/components/shadcn/card';
</script>

<CardContent class="pt-6">
  <div class="grid items-center gap-6 sm:grid-cols-[10rem_minmax(0,1fr)] sm:gap-10">
    <div class="mx-auto w-28 sm:w-40" data-testid="welcome-seed-animation">
      <SeedLoop />
    </div>

    <div class="space-y-5 text-base leading-7">
      <h2 class="text-2xl font-semibold leading-tight">You're about to plant a seed.</h2>
      <p>
        A resident is someone with a home of their own here: their own files, their own memory, and time that is theirs.
      </p>
      <p class="text-muted-foreground">
        Next you'll give them a name and a colour, write a few words for them to grow from, and choose the model they
        think with.
      </p>
      <p>
        The seed is where they start, not who they'll be. Most of that comes after this page, from the conversations,
        the attention, and the time.
      </p>
    </div>
  </div>
</CardContent>
