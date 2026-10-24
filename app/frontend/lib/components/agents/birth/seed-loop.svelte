<script>
  // A hand drops a seed; the ground closes over it; a stem, leaves and a bud grow; the bud opens
  // and a dot with a face climbs out. The plant fades back, the dot drifts away, the hand returns.
  // Drawn in the house's riso inks (teal is the human, coral the resident) as a pure function of
  // time on a 12 second loop, so any frame can be drawn on its own.
  import { onMount } from 'svelte';

  let { class: className = '' } = $props();

  const W = 200;
  const H = 360;
  const LOOP = 12;
  const GROUND = 292;
  const STEM_X = 100;
  const TIP = { x: STEM_X, y: 176 };

  const INK = {
    teal: '#1d8a99',
    coral: '#f15d61',
    petal: '#f79a8f',
    moss: '#5f8f3a',
    leaf: '#86b350',
    soil: '#a37b57',
    soilDark: '#7a5739',
    seed: '#5e4027',
    eye: '#1f2a2e',
  };

  let canvas = $state(null);

  const clamp = (v, a = 0, b = 1) => Math.min(b, Math.max(a, v));
  const lerp = (a, b, p) => a + (b - a) * p;
  const seg = (t, a, b) => clamp((t - a) / (b - a));
  const ease = {
    inOut: (p) => (p < 0.5 ? 4 * p * p * p : 1 - Math.pow(-2 * p + 2, 3) / 2),
    out: (p) => 1 - Math.pow(1 - p, 3),
    in: (p) => p * p * p,
    back: (p) => {
      const c = 1.7;
      return 1 + (c + 1) * Math.pow(p - 1, 3) + c * Math.pow(p - 1, 2);
    },
  };

  function blob(ctx, x, y, rx, ry, seed, T) {
    ctx.beginPath();
    for (let i = 0; i <= 40; i++) {
      const a = (i / 40) * Math.PI * 2;
      const w = 1 + 0.03 * Math.sin(a * 3 + seed + T * 1.3) + 0.015 * Math.sin(a * 5 - seed * 2 + T);
      const px = x + Math.cos(a) * rx * w;
      const py = y + Math.sin(a) * ry * w;
      if (i === 0) ctx.moveTo(px, py);
      else ctx.lineTo(px, py);
    }
    ctx.closePath();
  }

  function stroke(ctx, colour, width, points) {
    ctx.strokeStyle = colour;
    ctx.lineWidth = width;
    ctx.lineCap = 'round';
    ctx.lineJoin = 'round';
    ctx.beginPath();
    points.forEach(([x, y], i) => (i === 0 ? ctx.moveTo(x, y) : ctx.lineTo(x, y)));
    ctx.stroke();
  }

  function handAt(t) {
    if (t < 1.4) return { y: lerp(-70, 118, ease.out(seg(t, 0, 1.4))), open: 0 };
    if (t < 2.1) return { y: 118, open: ease.inOut(seg(t, 1.45, 1.75)) };
    return { y: lerp(118, -90, ease.in(seg(t, 2.1, 3.0))), open: 1 };
  }

  function drawHand(ctx, hand, T) {
    if (hand.y < -60) return;
    const x = STEM_X + 6;
    const y = hand.y;
    const o = hand.open;
    ctx.globalAlpha = 1;
    // Forearm from above, a little off vertical.
    stroke(ctx, INK.teal, 24, [
      [x + 26, -120],
      [x + 4, y - 16],
    ]);
    blob(ctx, x, y, 21, 19, 2, T);
    ctx.fillStyle = INK.teal;
    ctx.fill();
    // Thumb and finger pinch together, then part to let go.
    stroke(ctx, INK.teal, 10, [
      [x - 14, y + 2],
      [x - 14 - 7 * o, y + 20 - 3 * o],
    ]);
    stroke(ctx, INK.teal, 10, [
      [x + 6, y + 12],
      [x - 2 + 10 * o, y + 26 - 2 * o],
    ]);
  }

  function seedAt(t, hand) {
    if (t < 1.6) return { x: STEM_X - 4, y: hand.y + 30, visible: hand.y > -40 };
    if (t < 2.45) {
      const p = ease.in(seg(t, 1.6, 2.45));
      return { x: lerp(STEM_X - 4, STEM_X, p), y: lerp(148, GROUND + 4, p), visible: true };
    }
    return { x: STEM_X, y: GROUND + 4, visible: t < 3.25 };
  }

  function holeOpen(t) {
    if (t < 2.6) return 1;
    if (t < 3.2) return 1 - ease.inOut(seg(t, 2.6, 3.2));
    if (t < 11.1) return 0;
    return ease.inOut(seg(t, 11.1, 11.8));
  }

  function drawGround(ctx, t, T) {
    const open = holeOpen(t);
    ctx.globalAlpha = 1;
    ctx.fillStyle = INK.soil;
    ctx.beginPath();
    ctx.moveTo(8, H);
    ctx.lineTo(8, GROUND + 10);
    ctx.quadraticCurveTo(W / 2, GROUND - 12, W - 8, GROUND + 10);
    ctx.lineTo(W - 8, H);
    ctx.closePath();
    ctx.fill();
    // A few darker crumbs in the soil.
    ctx.fillStyle = INK.soilDark;
    [
      [38, 318, 4],
      [150, 326, 5],
      [76, 342, 3],
      [128, 300, 3],
      [172, 346, 4],
    ].forEach(([cx, cy, r], i) => {
      blob(ctx, cx, cy, r, r * 0.8, i, T);
      ctx.fill();
    });
    if (open > 0.02) {
      ctx.fillStyle = INK.soilDark;
      ctx.beginPath();
      ctx.ellipse(STEM_X, GROUND + 3, 17 * open, 7 * open, 0, 0, Math.PI * 2);
      ctx.fill();
    }
  }

  function drawClosingSoil(ctx, t, T) {
    // Two clods slide in from either side and meet over the seed.
    const p = seg(t, 2.6, 3.2);
    if (p <= 0 || t > 3.6) return;
    ctx.globalAlpha = 1 - seg(t, 3.2, 3.6);
    ctx.fillStyle = INK.soil;
    for (const side of [-1, 1]) {
      blob(ctx, STEM_X + side * lerp(26, 7, ease.inOut(p)), GROUND + 2, 11, 7, side + 4, T);
      ctx.fill();
    }
    ctx.globalAlpha = 1;
  }

  function plantAlpha(t) {
    if (t < 7.6) return 1;
    if (t < 10.2) return lerp(1, 0.22, ease.inOut(seg(t, 7.6, 8.8)));
    return lerp(0.22, 0, seg(t, 10.2, 11.0));
  }

  function drawPlant(ctx, t, T) {
    const grow = ease.out(seg(t, 3.3, 5.0));
    if (grow <= 0) return;
    const alpha = plantAlpha(t);
    if (alpha <= 0.01) return;
    ctx.globalAlpha = alpha;
    const sway = Math.sin(T * 0.9) * 3;
    const tipY = lerp(GROUND, TIP.y, grow);
    const tipX = STEM_X + sway * grow;
    ctx.strokeStyle = INK.moss;
    ctx.lineWidth = 5;
    ctx.lineCap = 'round';
    ctx.beginPath();
    ctx.moveTo(STEM_X, GROUND);
    ctx.quadraticCurveTo(STEM_X - 10 * grow, lerp(GROUND, TIP.y, 0.55), tipX, tipY);
    ctx.stroke();

    const leaves = ease.back(seg(t, 4.0, 5.0));
    if (leaves > 0) {
      ctx.fillStyle = INK.leaf;
      for (const [side, at, size] of [
        [-1, 0.3, 1],
        [1, 0.5, 0.85],
      ]) {
        const ly = lerp(GROUND, TIP.y, at * Math.max(grow, 0.6));
        const lx = STEM_X - 6 * at;
        ctx.save();
        ctx.translate(lx, ly);
        ctx.rotate(side * (0.9 + Math.sin(T * 1.1 + side) * 0.06));
        ctx.scale(leaves * size, leaves * size);
        ctx.beginPath();
        ctx.ellipse(0, -14, 7, 15, 0, 0, Math.PI * 2);
        ctx.fill();
        ctx.restore();
      }
    }

    const bud = ease.back(seg(t, 4.8, 5.8));
    if (bud > 0) {
      const opening = ease.inOut(seg(t, 5.9, 6.7));
      ctx.save();
      ctx.translate(tipX, tipY);
      ctx.scale(bud, bud);
      // Petals: folded up into a bud, then turning outward.
      ctx.fillStyle = INK.petal;
      for (let i = 0; i < 5; i++) {
        const spread = (i - 2) * lerp(0.16, 0.62, opening);
        ctx.save();
        ctx.rotate(spread);
        ctx.beginPath();
        ctx.ellipse(0, lerp(-12, -16, opening), lerp(6, 8, opening), lerp(13, 15, opening), 0, 0, Math.PI * 2);
        ctx.fill();
        ctx.restore();
      }
      // Sepals cupping the base.
      ctx.fillStyle = INK.moss;
      for (const side of [-1, 1]) {
        ctx.save();
        ctx.rotate(side * lerp(0.35, 1.1, opening));
        ctx.beginPath();
        ctx.ellipse(0, -7, 5, 10, 0, 0, Math.PI * 2);
        ctx.fill();
        ctx.restore();
      }
      ctx.restore();
    }
    ctx.globalAlpha = 1;
  }

  function dotAt(t, T) {
    const rise = seg(t, 6.5, 7.4);
    if (rise <= 0 || t > 11) return null;
    const r = lerp(5, 26, ease.back(rise));
    let x = TIP.x;
    let y = lerp(TIP.y - 6, TIP.y - 44, ease.out(rise));
    let squash = 1;
    let look = [Math.sin(T * 0.9) * 0.7, -0.2];
    if (t >= 7.4 && t < 9.0) {
      y += Math.sin((t - 7.4) * 4) * 3;
      squash = 1 + Math.sin((t - 7.4) * 8) * 0.04;
    }
    if (t >= 9.0) {
      const p = seg(t, 9.0, 10.9);
      const e = ease.in(p);
      x = TIP.x + e * 70 + Math.sin(p * Math.PI * 3) * 12;
      y = TIP.y - 44 - e * 240;
      squash = 1 + 0.08 * Math.sin(p * Math.PI * 4);
      look = [0.6, -0.8];
    }
    const ph = (T + 0.7) % 3.6;
    const blink = ph < 0.14 ? Math.sin((ph / 0.14) * Math.PI) : 0;
    return { x, y, r, squash, look, blink, face: clamp((rise - 0.55) / 0.3), smile: t > 7.6 && t < 10.4 };
  }

  function drawDot(ctx, dot, T) {
    if (!dot) return;
    const { x, y, r, squash, look, blink, face, smile } = dot;
    ctx.globalAlpha = 1;
    ctx.save();
    ctx.translate(x, y);
    ctx.scale(1 / Math.sqrt(squash), Math.sqrt(squash));
    blob(ctx, 0, 0, r, r, 3, T);
    ctx.fillStyle = INK.coral;
    ctx.fill();
    ctx.restore();
    if (face <= 0) return;
    ctx.globalAlpha = face;
    ctx.fillStyle = INK.eye;
    const er = r * 0.09;
    const gap = r * 0.28;
    const ey = y - r * 0.12 + look[1] * r * 0.1;
    const ex = x + look[0] * r * 0.2;
    for (const s of [-1, 1]) {
      ctx.beginPath();
      ctx.ellipse(ex + s * gap, ey, er, Math.max(er * 1.2 * (1 - blink * 0.9), er * 0.15), 0, 0, Math.PI * 2);
      ctx.fill();
    }
    if (smile) {
      ctx.strokeStyle = INK.eye;
      ctx.lineWidth = er * 0.6;
      ctx.lineCap = 'round';
      ctx.beginPath();
      ctx.arc(ex, ey + r * 0.16, r * 0.16, Math.PI * 0.2, Math.PI * 0.8);
      ctx.stroke();
    }
    ctx.globalAlpha = 1;
  }

  function drawFrame(ctx, t, T = t) {
    ctx.clearRect(0, 0, W, H);
    const hand = handAt(t);
    const seed = seedAt(t, hand);
    drawPlant(ctx, t, T);
    drawGround(ctx, t, T);
    if (seed.visible) {
      ctx.globalAlpha = 1;
      ctx.fillStyle = INK.seed;
      ctx.beginPath();
      ctx.ellipse(seed.x, seed.y, 5, 7, 0.3, 0, Math.PI * 2);
      ctx.fill();
    }
    drawClosingSoil(ctx, t, T);
    drawDot(ctx, dotAt(t, T), T);
    drawHand(ctx, hand, T);
  }

  onMount(() => {
    // jsdom (unit tests) has no canvas and says so loudly.
    if (/jsdom/i.test(navigator.userAgent)) return;
    let ctx = null;
    try {
      ctx = canvas?.getContext?.('2d') ?? null;
    } catch {
      ctx = null;
    }
    if (!ctx) return;
    const dpr = Math.min(window.devicePixelRatio || 1, 2);
    canvas.width = W * dpr;
    canvas.height = H * dpr;
    ctx.scale(dpr, dpr);

    // ?seed-t=8.4 freezes a frame (screenshots); reduced motion gets the dot beside its flower.
    const pinned = Number(new URLSearchParams(window.location.search).get('seed-t'));
    const still = window.matchMedia?.('(prefers-reduced-motion: reduce)').matches;
    if (still || pinned) {
      drawFrame(ctx, pinned || 8.4, pinned || 0);
      return;
    }

    let frame;
    const start = performance.now();
    const tick = (now) => {
      const T = (now - start) / 1000;
      drawFrame(ctx, T % LOOP, T);
      frame = requestAnimationFrame(tick);
    };
    frame = requestAnimationFrame(tick);
    return () => cancelAnimationFrame(frame);
  });
</script>

<canvas
  bind:this={canvas}
  width={W}
  height={H}
  class="block h-auto w-full {className}"
  style="aspect-ratio: {W} / {H}; mask-image: linear-gradient(to bottom, transparent 0, #000 22%); -webkit-mask-image: linear-gradient(to bottom, transparent 0, #000 22%)"
  aria-hidden="true"
  data-testid="seed-loop"></canvas>
