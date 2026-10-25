// The Siri orb, drawn as the app draws it: a port of OrbFrame in
// mac/Sources/HomebotUI/Views/SiriOrb.swift, layer for layer, with the same hues, paces and
// sizes. Homebot's own drawing; nothing is taken from Apple's Siri animation.
//  - A dark glass sphere; four soft bands of light (magenta, blue, cyan, orange) sweeping inside
//    it, running white where they cross; a coloured rim and a highlight; a soft bloom around it.
//  - The canvas is BLOOM times the sphere, so the glow has room. Every motion repeats once per
//    PERIOD seconds.

export const BLOOM = 1.5;
export const PERIOD = 24;
/** The still frame (reduced motion): the bands spread, all four hues showing. */
export const STILL = 5;
const W = (2 * Math.PI) / PERIOD;
const BANDS = ["#ff2bd6", "#2f5bff", "#22e6ff", "#ff8a1f"];
const deg = (d: number) => (d * Math.PI) / 180;

let filterOk: boolean | null = null;
/** Canvas blur filters: missing in some browsers, where layers are drawn sharp but softened by a downscale. */
function canFilter(g: CanvasRenderingContext2D) {
  if (filterOk === null) {
    g.save();
    g.filter = "blur(2px)";
    filterOk = g.filter === "blur(2px)";
    g.restore();
  }
  return filterOk;
}

/** Draws `paint` blurred by `r` px onto `g`, with `alpha` and the composite op `op`. */
function blurred(g: CanvasRenderingContext2D, r: number, alpha: number, op: GlobalCompositeOperation, paint: (g: CanvasRenderingContext2D) => void) {
  g.save();
  g.globalAlpha = alpha;
  g.globalCompositeOperation = op;
  if (canFilter(g)) {
    g.filter = `blur(${r}px)`;
    paint(g);
  } else {
    // A low-resolution copy, scaled back up with smoothing, reads as a blur.
    const k = Math.max(1, r / 1.5);
    const w = g.canvas.width;
    const h = g.canvas.height;
    const tmp = scratch(Math.ceil(w / k), Math.ceil(h / k));
    const t = tmp.getContext("2d")!;
    t.clearRect(0, 0, tmp.width, tmp.height);
    t.save();
    t.scale(1 / k, 1 / k);
    paint(t);
    t.restore();
    g.imageSmoothingEnabled = true;
    g.imageSmoothingQuality = "high";
    g.drawImage(tmp, 0, 0, tmp.width, tmp.height, 0, 0, w, h);
  }
  g.restore();
}

const pool: HTMLCanvasElement[] = [];
let used = 0;
function scratch(w: number, h: number) {
  const c = (pool[used] ??= document.createElement("canvas"));
  used++;
  if (c.width !== w) c.width = w;
  if (c.height !== h) c.height = h;
  return c;
}

/** One frame of the orb at time `t` (s): a sphere of `S` px centred on a canvas of BLOOM × S. */
export function drawOrb(g: CanvasRenderingContext2D, S: number, t: number) {
  used = 0;
  const C = (S * BLOOM) / 2;
  g.clearRect(0, 0, g.canvas.width, g.canvas.height);

  // The soft light around the orb, in the bands' colours; normal blending, for light and dark pages.
  blurred(g, S * 0.13, 0.55, "source-over", (x) => {
    const con = x.createConicGradient(deg(t * 15), C, C);
    BANDS.forEach((c, i) => con.addColorStop(i / 4, c));
    con.addColorStop(1, BANDS[0]);
    x.fillStyle = con;
    x.beginPath();
    x.arc(C, C, (S * 0.98) / 2, 0, Math.PI * 2);
    x.fill();
  });

  // The sphere, on its own layer so its feathered edge can be masked.
  const L = scratch(Math.ceil(S * BLOOM), Math.ceil(S * BLOOM));
  const s = L.getContext("2d")!;
  s.clearRect(0, 0, L.width, L.height);
  // Dark glass, a little lighter at the bottom where light passes through.
  const glass = s.createRadialGradient(C, C - S / 2 + S * 0.62, 0, C, C - S / 2 + S * 0.62, S * 0.55);
  glass.addColorStop(0, "#2a1f6b");
  glass.addColorStop(1, "#07051a");
  s.fillStyle = glass;
  s.fillRect(C - S / 2, C - S / 2, S, S);

  // Four luminous bands: thick, soft open arcs sweeping round inside, each at its own pace.
  for (let i = 0; i < 4; i++) {
    const k = i;
    const turn = t * 15 * (i % 2 === 0 ? 1 : -1) * (1 + (i % 2)) + k * 90;
    const lift = Math.sin(t * W * (1 + (i % 2)) + k * 1.7) * 0.12;
    const squash = 0.42 + 0.12 * Math.sin(t * W * (2 + (i % 2)) + k);
    const reach = [0.92, 0.8, 0.86, 0.72][i];
    const span = 0.42 + 0.08 * Math.sin(t * W * 2 + k * 2.3);
    blurred(s, S * 0.05, 0.95, "lighter", (x) => {
      x.translate(C, C + S * lift);
      x.rotate(deg(turn));
      x.strokeStyle = BANDS[i];
      x.lineWidth = S * 0.13;
      x.lineCap = "round";
      x.beginPath();
      x.ellipse(0, 0, (S * reach) / 2, (S * squash * reach) / 2, 0, 0, span * Math.PI * 2);
      x.stroke();
    });
  }

  // Where the bands cross, the light runs white.
  s.save();
  s.globalCompositeOperation = "lighter";
  const wx = C - S / 2 + S * (0.5 + 0.06 * Math.sin(t * W * 2));
  const wy = C - S / 2 + S * 0.52;
  const white = s.createRadialGradient(wx, wy, 0, wx, wy, S * 0.16);
  white.addColorStop(0, `rgba(255,255,255,${0.4 + 0.1 * Math.sin(t * W * 3)})`);
  white.addColorStop(1, "rgba(255,255,255,0)");
  s.fillStyle = white;
  s.fillRect(C - S / 2, C - S / 2, S, S);
  s.restore();

  // The glass: a soft rim in the bands' colours inside the feathered edge, and a highlight on top.
  const feather = Math.max(0.6, S * 0.034);
  const lw = Math.max(1, S * 0.05);
  blurred(s, Math.max(0.5, S * 0.025), 0.5, "lighter", (x) => {
    const con = x.createConicGradient(deg(-t * 15 + 90), C, C);
    BANDS.forEach((c, i) => con.addColorStop(i / 4, c));
    con.addColorStop(1, BANDS[0]);
    x.strokeStyle = con;
    x.lineWidth = lw;
    x.beginPath();
    x.arc(C, C, S / 2 - feather * 0.6 - lw / 2, 0, Math.PI * 2);
    x.stroke();
  });
  blurred(s, S * 0.03, 1, "lighter", (x) => {
    const top = C - S * 0.3 - S * 0.13;
    const lin = x.createLinearGradient(0, top, 0, top + S * 0.26);
    lin.addColorStop(0, "rgba(255,255,255,0.32)");
    lin.addColorStop(1, "rgba(255,255,255,0)");
    x.fillStyle = lin;
    x.beginPath();
    x.ellipse(C, C - S * 0.3, S * 0.27, S * 0.13, 0, 0, Math.PI * 2);
    x.fill();
  });

  // A feathered edge, not a hard clip: opaque to `feather` inside the rim, clear at the rim.
  s.save();
  s.globalCompositeOperation = "destination-in";
  const mask = s.createRadialGradient(C, C, 0, C, C, S / 2);
  mask.addColorStop(Math.max(0, 1 - feather / (S / 2)), "#fff");
  mask.addColorStop(1, "rgba(255,255,255,0)");
  s.fillStyle = mask;
  s.fillRect(0, 0, L.width, L.height);
  s.restore();

  g.drawImage(L, 0, 0);
}
