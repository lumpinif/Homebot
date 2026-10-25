// Homebot's live logo: the app's mark (a roofline over two eyes, Brand.swift's MarkDrawing) on a
// flowing glow in the Siri orb's hues (orb.ts) and the Glow icon's warmth. The glyph is alive:
// its eyes look around, blink and glance, and now and then it hops or tilts; when a pointer
// comes near, the eyes follow it (LiveMark.swift's gaze) and the glow lifts.
//
// One controller per logo moves the glyph; it redraws only while something is moving. The
// background's flow and breathing are CSS animations in the DOM (index.css, .hb-logo) and a
// low-rate redraw on the Mac's screen in the device row. Under reduced motion, off screen or in
// a hidden tab, nothing moves and nothing is scheduled.

/** The mark's grid: the SVG's viewBox is 5 5 54 54. */
export const ROOF = "M17 31 32 19l15 12";
export const EYES_X = [23.3, 35.3];
/** The glyph tilts around this point, between roof and eyes. */
export const PIVOT = [32, 36] as const;

/** The flowing light: the orb's four bands and the Glow icon's warm red. */
export const FLOW = ["#ff2bd6", "#2f5bff", "#22e6ff", "#ff8a1f", "#ff2555"];
const BASE = "#0d0b1a";

/** Where the eyes look (LiveMark.swift, EyeGaze). */
const REACH = 220;
const MAX_X = 3.2;
const MAX_Y = 2.4;

/** The eye offset, in grid units, for a pointer at (vx, vy) px from the logo's centre (y down);
 *  null when farther than REACH. Full turn once the pointer is past the logo's edge. */
function gazeFor(vx: number, vy: number, size: number): [number, number] | null {
  const d = Math.hypot(vx, vy);
  if (!isFinite(d) || d > REACH) return null;
  if (d <= 0.5) return [0, 0];
  const ramp = Math.min(1, d / Math.max(size, 1));
  const ux = vx / d;
  const uy = vy / d;
  const k = 1 / Math.sqrt((ux * ux) / (MAX_X * MAX_X) + (uy * uy) / (MAX_Y * MAX_Y));
  // Rounded to 0.1 unit, so small pointer moves don't each start a new movement.
  const q = (v: number) => Math.round(v * 10) / 10;
  return [q(ux * k * ramp), q(uy * k * ramp)];
}

/** One eye's rectangle for a blink amount (1 open, 0.12 shut): it scales around y = 40. */
export function eyeRect(x: number, gx: number, gy: number, blink: number) {
  const h = 11 * blink;
  return { x: x + gx, y: 40 - 5.5 * blink + gy, w: 5.4, h, r: Math.min(2.7, h / 2) };
}

export type MarkState = {
  gx: number;
  gy: number;
  blink: number;
  /** The glyph's vertical offset (grid units, negative is up) and tilt (degrees). */
  hop: number;
  tilt: number;
  /** How far the glow has lifted for a pointer nearby, 0 to 1. */
  lift: number;
};
export const REST: MarkState = { gx: 0, gy: 0, blink: 1, hop: 0, tilt: 0, lift: 0 };

/**
 * Draws the logo on a canvas: `size` px square at (x, y), the light flowing at time `t` (s).
 * The same look as the DOM logo, from soft radial patches instead of blurred layers.
 */
export function drawMark(g: CanvasRenderingContext2D, x: number, y: number, size: number, t: number, s: MarkState = REST) {
  g.save();
  g.translate(x, y);
  g.beginPath();
  g.roundRect(0, 0, size, size, size * 0.2237);
  g.save();
  g.clip();
  g.fillStyle = BASE;
  g.fillRect(0, 0, size, size);
  FLOW.forEach((c, i) => {
    // Each patch drifts on its own slow loop, lower in the square than higher.
    const a = t * (0.21 + i * 0.037) + i * 1.9;
    const px = size * (0.5 + 0.34 * Math.cos(a));
    const py = size * (0.66 + 0.24 * Math.sin(a * 1.3 + i));
    const grad = g.createRadialGradient(px, py, 0, px, py, size * 0.48);
    grad.addColorStop(0, c + "eb");
    grad.addColorStop(0.45, c + "8c");
    grad.addColorStop(1, c + "00");
    g.fillStyle = grad;
    g.fillRect(0, 0, size, size);
  });
  // Warm breath at the bottom edge, stronger when lifted.
  const breath = 0.32 + 0.1 * Math.sin(t * 1.3) + 0.3 * s.lift;
  const warm = g.createRadialGradient(size / 2, size * 1.1, 0, size / 2, size * 1.1, size * 0.7);
  warm.addColorStop(0, `rgba(255,150,70,${breath})`);
  warm.addColorStop(1, "rgba(255,60,110,0)");
  g.fillStyle = warm;
  g.fillRect(0, 0, size, size);
  // A darker top, so the white roof reads.
  const shade = g.createLinearGradient(0, 0, 0, size * 0.62);
  shade.addColorStop(0, "rgba(8,6,20,0.7)");
  shade.addColorStop(1, "rgba(8,6,20,0)");
  g.fillStyle = shade;
  g.fillRect(0, 0, size, size);
  // A vignette that keeps all four corners dark, over the warm breath.
  const vig = g.createRadialGradient(size / 2, size / 2, 0, size / 2, size / 2, size * 0.7071);
  vig.addColorStop(0.45, "rgba(8,5,20,0)");
  vig.addColorStop(1, "rgba(8,5,20,0.8)");
  g.fillStyle = vig;
  g.fillRect(0, 0, size, size);
  g.restore();
  g.strokeStyle = "rgba(255,255,255,0.14)";
  g.lineWidth = Math.max(0.5, size / 64);
  g.stroke();

  const u = size / 54;
  g.scale(u, u);
  g.translate(-5, -5 + s.hop);
  g.translate(PIVOT[0], PIVOT[1]);
  g.rotate((s.tilt * Math.PI) / 180);
  g.translate(-PIVOT[0], -PIVOT[1]);
  g.strokeStyle = "#fff";
  g.fillStyle = "#fff";
  g.lineWidth = 4.6;
  g.lineCap = "round";
  g.lineJoin = "round";
  g.stroke(new Path2D(ROOF));
  for (const ex of EYES_X) {
    const r = eyeRect(ex, s.gx, s.gy, s.blink);
    g.beginPath();
    g.roundRect(r.x, r.y, r.w, r.h, r.r);
    g.fill();
  }
  g.restore();
}

// ------------------------------------------------------------------ the pointer, shared

type Pointer = { x: number; y: number } | null;
let pointer: Pointer = null;
const listeners = new Set<() => void>();
let wired = false;
function wire() {
  if (wired) return;
  wired = true;
  const tell = () => listeners.forEach((f) => f());
  // Only a mouse or pen: on touch there is no pointer to follow.
  addEventListener(
    "pointermove",
    (e) => {
      if (e.pointerType === "touch") return;
      pointer = { x: e.clientX, y: e.clientY };
      tell();
    },
    { passive: true },
  );
  const away = () => {
    pointer = null;
    tell();
  };
  document.addEventListener("pointerleave", away);
  addEventListener("blur", away);
  // Scrolling moves the logo under a still pointer: look again.
  addEventListener("scroll", tell, { passive: true, capture: true });
}

// ------------------------------------------------------------------ springs, as SwiftUI's

type Spring = { x: number; v: number; to: number; k: number; c: number };
const spring = (): Spring => ({ x: 0, v: 0, to: 0, k: 0, c: 0 });
/** SwiftUI's .spring(response:dampingFraction:) on a unit mass. */
function aim(s: Spring, to: number, response: number, damping: number) {
  s.to = to;
  s.k = ((2 * Math.PI) / response) ** 2;
  s.c = (4 * Math.PI * damping) / response;
}
function step(s: Spring, dt: number) {
  const a = -s.k * (s.x - s.to) - s.c * s.v;
  s.v += a * dt;
  s.x += s.v * dt;
  if (Math.abs(s.x - s.to) < 0.004 && Math.abs(s.v) < 0.01) {
    s.x = s.to;
    s.v = 0;
    return false;
  }
  return true;
}

const ease = {
  in: (t: number) => t * t,
  out: (t: number) => 1 - (1 - t) * (1 - t),
};

/**
 * Brings one logo to life. `where` gives its centre and size in client px (null: nowhere to look
 * from); `draw` applies a state; `onLive` says when the logo starts or stops moving at all (off
 * screen, hidden tab, reduced motion), so its CSS animations can pause with it. `watch` is the
 * element whose visibility gates it.
 */
export function liveMark(opts: {
  watch: Element;
  where: () => { x: number; y: number; size: number } | null;
  draw: (s: MarkState) => void;
  onLive?: (live: boolean) => void;
  reduce: boolean;
}) {
  const gx = spring();
  const gy = spring();
  const hop = spring();
  const tilt = spring();
  const lift = spring();
  const all = [gx, gy, hop, tilt, lift];
  let follow: [number, number] | null = null;
  let glance: [number, number] = [0, 0];
  let blink = 1;
  let blinkAt = -1; // start of a blink, ms; -1 none
  let shut = false; // this blink has shown the eyes shut
  let frame = 0;
  let last = 0;
  let onScreen = false;
  let reduce = opts.reduce;
  let wasLive: boolean | null = null;
  const timers = new Set<number>();
  const later = (ms: number, f: () => void) => {
    const id = window.setTimeout(() => {
      timers.delete(id);
      f();
    }, ms);
    timers.add(id);
  };
  const live = () => !reduce && onScreen && !document.hidden;

  const draw = () => opts.draw({ gx: gx.x, gy: gy.x, blink, hop: hop.x, tilt: tilt.x, lift: lift.x });
  const gaze = () => {
    const [x, y] = follow ?? glance;
    // Quick toward the pointer; slower and softer on the way back to centre (LiveMark.swift).
    const [r, d] = follow ? [0.35, 0.78] : glance[0] || glance[1] ? [0.4, 0.8] : [0.7, 0.85];
    aim(gx, x, r, d);
    aim(gy, y, r, d);
    aim(lift, follow ? 1 : 0, 0.6, 1);
    kick();
  };
  const tick = (now: number) => {
    frame = 0;
    const dt = last ? Math.min((now - last) / 1000, 0.05) : 1 / 60;
    last = now;
    let busy = false;
    // Small steps keep the stiff springs stable.
    for (let i = 0; i < 4; i++) for (const s of all) busy = step(s, dt / 4) || busy;
    if (blinkAt >= 0) {
      // Shut in 70 ms (ease in), hold, open over 140 ms from 90 ms (ease out). A slow frame
      // never skips the shut eyes: it shows them and the opening starts from there.
      let t = now - blinkAt;
      if (t >= 70 && !shut) {
        shut = true;
        blinkAt = now - 70;
        t = 70;
      }
      if (t < 70) blink = 1 - 0.88 * ease.in(t / 70);
      else if (t < 90) blink = 0.12;
      else if (t < 230) blink = 0.12 + 0.88 * ease.out((t - 90) / 140);
      else {
        blink = 1;
        blinkAt = -1;
      }
      busy = true;
    }
    draw();
    if (busy) frame = requestAnimationFrame(tick);
    else last = 0;
  };
  const kick = () => {
    if (!frame) frame = requestAnimationFrame(tick);
  };

  const look = () => {
    if (!live()) return;
    const at = pointer && opts.where();
    const g = at && pointer ? gazeFor(pointer.x - at.x, pointer.y - at.y, at.size) : null;
    if (g?.[0] === follow?.[0] && g?.[1] === follow?.[1]) return;
    follow = g;
    gaze();
  };

  // The idle life. Each gap of 3.5–7 s ends in a blink (sometimes a double one); in about half
  // the gaps the eyes first look somewhere, and in about a third the glyph hops or tilts.
  const rand = (a: number, b: number) => a + Math.random() * (b - a);
  const blinkNow = () => {
    blinkAt = performance.now();
    shut = false;
    kick();
  };
  const acts = {
    blink() {
      blinkNow();
      if (Math.random() < 0.2) later(320, blinkNow);
    },
    look() {
      if (follow) return;
      const side = Math.random() < 0.5 ? -1 : 1;
      glance = [side * rand(1.6, 2.8), rand(-1.2, 0.9)];
      gaze();
      later(rand(700, 1300), () => {
        glance = [0, 0];
        gaze();
      });
    },
    hop() {
      aim(hop, -rand(1.6, 2.4), 0.18, 0.6);
      kick();
      later(140, () => {
        aim(hop, 0, 0.32, 0.45);
        kick();
      });
    },
    tilt() {
      aim(tilt, (Math.random() < 0.5 ? -1 : 1) * rand(5, 8), 0.45, 0.6);
      kick();
      later(rand(600, 1000), () => {
        aim(tilt, 0, 0.55, 0.5);
        kick();
      });
    },
  };
  const plan = () => {
    if (!live()) return;
    const gap = rand(3.5, 7) * 1000;
    if (Math.random() < 0.5) later(rand(0.25, 0.55) * gap, acts.look);
    if (Math.random() < 0.35) later(rand(0.6, 0.85) * gap, Math.random() < 0.5 ? acts.hop : acts.tilt);
    later(gap, () => {
      acts.blink();
      plan();
    });
  };

  const start = () => {
    if (!live()) return;
    plan();
    look();
  };
  const stop = () => {
    timers.forEach(clearTimeout);
    timers.clear();
    cancelAnimationFrame(frame);
    frame = 0;
    last = 0;
    follow = null;
    glance = [0, 0];
    blink = 1;
    blinkAt = -1;
    for (const s of all) s.x = s.to = s.v = 0;
    draw();
  };
  const restart = () => {
    stop();
    const now = live();
    if (now !== wasLive) opts.onLive?.(now);
    wasLive = now;
    start();
  };

  wire();
  listeners.add(look);
  const io = new IntersectionObserver(([e]) => {
    onScreen = e.isIntersecting;
    restart();
  });
  io.observe(opts.watch);
  document.addEventListener("visibilitychange", restart);
  draw();

  return {
    isLive: live,
    setReduce(v: boolean) {
      reduce = v;
      restart();
    },
    dispose() {
      stop();
      listeners.delete(look);
      io.disconnect();
      document.removeEventListener("visibilitychange", restart);
    },
  };
}
