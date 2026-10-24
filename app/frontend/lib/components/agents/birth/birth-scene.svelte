<script>
  // The house mark (a roof over a warm dot) drawn as the resident comes together.
  // Each step of the form moves the small dots somewhere new, and the roof draws in as you go.
  let { step = 0, colour = null, processing = false } = $props();

  const centre = { x: 120, y: 140 };
  // Eight small dots. `scatter` is where they wander at the start; the ring and the row are computed.
  const scatter = [
    { x: 24, y: 60 },
    { x: 58, y: 168 },
    { x: 216, y: 56 },
    { x: 192, y: 176 },
    { x: 34, y: 124 },
    { x: 224, y: 124 },
    { x: 84, y: 30 },
    { x: 162, y: 20 },
  ];
  const coreScales = [0.28, 0.55, 0.5, 0.7, 1];

  function placeFor(index, currentStep) {
    if (currentStep <= 1) return scatter[index];
    if (currentStep === 2) {
      const angle = (index / scatter.length) * Math.PI * 2;
      return { x: centre.x + Math.cos(angle) * 84, y: centre.y + Math.sin(angle) * 54 };
    }
    if (currentStep === 3) return { x: 50 + index * 20, y: 200 };
    return centre;
  }

  const roofLength = 260;
  let roofDrawn = $derived(Math.min(1, (step + 1) / 5));
  let coreScale = $derived(coreScales[step] ?? coreScales[0]);
  let satelliteOpacity = $derived(step === 1 ? (colour ? 0.75 : 0.3) : step >= 4 ? 0 : 0.85);
  let coreColour = $derived(colour ? `text-${colour}-400` : 'text-[var(--account-dot,#f15d61)]');
  let hopping = $derived(step === 3 || processing);

  // Once a colour is chosen the small dots stop being house-red and take colours that sit
  // with it: its complement and the two hues either side of the complement.
  const hues = [
    'red',
    'orange',
    'amber',
    'yellow',
    'lime',
    'green',
    'emerald',
    'teal',
    'cyan',
    'sky',
    'blue',
    'indigo',
    'violet',
    'purple',
    'fuchsia',
    'pink',
    'rose',
  ];
  let satelliteColours = $derived.by(() => {
    const at = hues.indexOf(colour);
    if (at < 0) return null;
    return [8, 6, 10].map((offset) => `text-${hues[(at + offset) % hues.length]}-400`);
  });

  function satelliteColour(index) {
    if (satelliteColours) return satelliteColours[index % satelliteColours.length];
    return index % 3 === 0 ? 'text-[var(--account-dot,#f15d61)]' : 'text-primary/60';
  }
</script>

<div class="mx-auto w-full max-w-[15rem]" aria-hidden="true" data-testid="birth-scene" data-step={step}>
  <svg viewBox="0 0 240 220" class="w-full overflow-visible">
    <path
      d="M16 100 L120 24 L224 100"
      fill="none"
      stroke="currentColor"
      class="text-foreground/10"
      stroke-width="20"
      stroke-linecap="round"
      stroke-linejoin="round" />
    <path
      d="M16 100 L120 24 L224 100"
      fill="none"
      stroke="currentColor"
      class="text-foreground/80"
      stroke-width="20"
      stroke-linecap="round"
      stroke-linejoin="round"
      stroke-dasharray={roofLength}
      stroke-dashoffset={roofLength * (1 - roofDrawn)}
      style="transition: stroke-dashoffset 900ms cubic-bezier(0.22, 1, 0.36, 1)" />

    <g class:orbiting={step === 2} style="transform-origin: {centre.x}px {centre.y}px">
      {#each scatter as _, index (index)}
        {@const place = placeFor(index, step)}
        <g
          class="satellite-place"
          style="transform: translate({place.x}px, {place.y}px); opacity: {satelliteOpacity}; transition-delay: {index *
            45}ms">
          <circle
            r="6"
            fill="currentColor"
            class="satellite {hopping ? 'hop' : step <= 1 ? 'drift' : ''} {satelliteColour(index)}"
            style="animation-delay: {index * (hopping ? 110 : 370)}ms" />
        </g>
      {/each}
    </g>

    <g class="core-place" style="transform: translate({centre.x}px, {centre.y}px) scale({coreScale})">
      <circle
        r="58"
        fill="currentColor"
        class="core {coreColour}"
        class:breathe={step < 4 && !processing}
        class:glow={step === 4 && !processing}
        class:hop={processing} />
    </g>
  </svg>
</div>

<style>
  .satellite-place {
    transition:
      transform 1000ms cubic-bezier(0.34, 1.3, 0.64, 1),
      opacity 700ms ease;
  }
  .core-place {
    transition: transform 900ms cubic-bezier(0.34, 1.56, 0.64, 1);
  }
  .core {
    transition: color 600ms ease;
  }
  .satellite {
    transition: color 900ms ease;
  }
  .satellite,
  .core {
    transform-box: fill-box;
    transform-origin: center;
  }
  .drift {
    animation: drift 4.2s ease-in-out infinite alternate;
  }
  .hop {
    animation: hop 0.9s cubic-bezier(0.33, 0, 0.66, 1) infinite;
  }
  .breathe {
    animation: breathe 3.4s ease-in-out infinite;
  }
  .glow {
    animation: glow 2.8s ease-in-out infinite;
  }
  .orbiting {
    animation: orbit 14s linear infinite;
  }

  @keyframes drift {
    from {
      transform: translate(-4px, 3px);
    }
    to {
      transform: translate(5px, -4px);
    }
  }
  @keyframes hop {
    0%,
    100% {
      transform: translateY(0) scale(1, 1);
    }
    15% {
      transform: translateY(0) scale(1.15, 0.85);
    }
    45% {
      transform: translateY(-16px) scale(0.92, 1.08);
    }
    75% {
      transform: translateY(0) scale(1.1, 0.9);
    }
  }
  @keyframes breathe {
    0%,
    100% {
      transform: scale(1);
    }
    50% {
      transform: scale(1.08);
    }
  }
  @keyframes glow {
    0%,
    100% {
      filter: drop-shadow(0 0 0 currentColor);
    }
    50% {
      filter: drop-shadow(0 0 12px currentColor);
    }
  }
  @keyframes orbit {
    to {
      transform: rotate(360deg);
    }
  }

  @media (prefers-reduced-motion: reduce) {
    .drift,
    .hop,
    .breathe,
    .glow,
    .orbiting {
      animation: none;
    }
    .satellite-place,
    .core-place {
      transition: opacity 300ms ease;
    }
  }
</style>
