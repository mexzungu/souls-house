<script>
  import { onMount } from 'svelte';

  // A small memory graph. A moment in the conversation lights one memory, then the memories linked to it,
  // then the ones linked to those. One memory is private and stays dark. Then another moment, another anchor.
  const nodes = [
    { x: 40, y: 50 },
    { x: 95, y: 28 },
    { x: 150, y: 62 },
    { x: 92, y: 102 },
    { x: 205, y: 30 },
    { x: 262, y: 58 },
    { x: 212, y: 112 },
    { x: 150, y: 148 },
    { x: 48, y: 148 },
    { x: 280, y: 140 },
    { x: 304, y: 92 },
  ];
  const edges = [
    [0, 1],
    [1, 2],
    [0, 3],
    [2, 3],
    [2, 4],
    [4, 5],
    [2, 6],
    [6, 7],
    [3, 7],
    [3, 8],
    [6, 9],
    [5, 10],
    [9, 10],
    [7, 8],
  ];
  const privateNode = 6;
  const anchors = [2, 8, 5];

  function hopsFrom(start) {
    const dist = Array(nodes.length).fill(Infinity);
    dist[start] = 0;
    const queue = [start];
    while (queue.length) {
      const n = queue.shift();
      for (const [a, b] of edges) {
        const m = a === n ? b : b === n ? a : null;
        if (m !== null && m !== privateNode && dist[m] === Infinity) {
          dist[m] = dist[n] + 1;
          queue.push(m);
        }
      }
    }
    return dist;
  }

  let anchorIndex = $state(0);
  let reach = $state(2); // how many hops out have lit; -1 means nothing yet
  const dist = $derived(hopsFrom(anchors[anchorIndex]));
  const lit = (n) => dist[n] <= reach;
  const edgeLit = ([a, b]) => lit(a) && lit(b);

  onMount(() => {
    if (window.matchMedia?.('(prefers-reduced-motion: reduce)').matches) return;
    let t = 0;
    reach = -1;
    const timer = setInterval(() => {
      t += 1;
      if (t <= 3) reach = t - 1;
      else if (t > 7) {
        t = 0;
        reach = -1;
        anchorIndex = (anchorIndex + 1) % anchors.length;
      }
    }, 650);
    return () => clearInterval(timer);
  });
</script>

<div class="rounded-3xl border bg-background p-6 shadow-sm" aria-hidden="true" data-testid="memory-graph">
  <svg viewBox="0 0 340 180" class="w-full">
    {#each edges as edge, i (i)}
      <line
        x1={nodes[edge[0]].x}
        y1={nodes[edge[0]].y}
        x2={nodes[edge[1]].x}
        y2={nodes[edge[1]].y}
        class="stroke-foreground transition-all duration-500"
        stroke-width="1.5"
        stroke-opacity={edgeLit(edge) ? 0.55 : 0.12} />
    {/each}
    {#each nodes as node, n (n)}
      {#if n === privateNode}
        <circle
          cx={node.x}
          cy={node.y}
          r="8"
          class="fill-background stroke-foreground"
          stroke-width="1.5"
          stroke-dasharray="3 3"
          stroke-opacity="0.4" />
      {:else}
        <circle
          cx={node.x}
          cy={node.y}
          r={dist[n] === 0 && reach >= 0 ? 10 : 8}
          class="transition-all duration-500 {dist[n] === 0 && reach >= 0
            ? 'fill-primary'
            : lit(n)
              ? 'fill-foreground/70'
              : 'fill-muted stroke-foreground/20'}"
          stroke-width="1" />
      {/if}
    {/each}
  </svg>
  <div class="mt-3 flex flex-wrap justify-between gap-2 text-[11px] text-muted-foreground">
    <span>one memory brings back the ones linked to it</span>
    <span>the private one stays dark</span>
  </div>
</div>
