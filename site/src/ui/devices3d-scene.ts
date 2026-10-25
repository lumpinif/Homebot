// The three devices of the flow, modelled here from plain three.js geometry: no scanned or
// downloaded models, no images of Apple's. A fabric speaker with a lit top (HomePod mini-like),
// a phone, and a laptop showing Homebot's mark. Textures are drawn on canvases at load. The
// light on the speaker and phone is the app's own Siri orb (orb.ts), not Apple's.
// Shown front on through an orthographic camera, as in a product shot (the speaker from just
// above level, so its lit top shows). Loaded on demand by devices3d.tsx; renders only when
// something changes or while lit.
import {
  ACESFilmicToneMapping,
  AdditiveBlending,
  BoxGeometry,
  CanvasTexture,
  CircleGeometry,
  Color,
  DirectionalLight,
  Group,
  LatheGeometry,
  Mesh,
  MeshBasicMaterial,
  MeshPhysicalMaterial,
  MeshStandardMaterial,
  OrthographicCamera,
  PlaneGeometry,
  PMREMGenerator,
  RingGeometry,
  RepeatWrapping,
  Scene,
  SRGBColorSpace,
  Vector2,
  Vector3,
  WebGLRenderer,
  type Material,
  type Texture,
} from "three";
import { RoomEnvironment } from "three/examples/jsm/environments/RoomEnvironment.js";
import { RoundedBoxGeometry } from "three/examples/jsm/geometries/RoundedBoxGeometry.js";
import { drawMark, liveMark, REST, type MarkState } from "./mark";
import { BLOOM, drawOrb, PERIOD, STILL } from "./orb";

export type DeviceKind = "homepod" | "iphone" | "mac";
export type DeviceHandle = {
  setLit: (on: boolean) => void;
  setDark: (on: boolean) => void;
  setReduce: (on: boolean) => void;
  dispose: () => void;
};


function canvas(w: number, h: number) {
  const c = document.createElement("canvas");
  c.width = w;
  c.height = h;
  return [c, c.getContext("2d")!] as const;
}

function texture(c: HTMLCanvasElement, srgb = true) {
  const t = new CanvasTexture(c);
  if (srgb) t.colorSpace = SRGBColorSpace;
  t.anisotropy = 4;
  return t;
}

/** The app's Siri orb (orb.ts) on a canvas texture; `play` moves it on. */
function orbTexture() {
  const px = 384;
  const [c, g] = canvas(px, px);
  let t = STILL;
  drawOrb(g, px / BLOOM, t);
  const tex = texture(c);
  return {
    tex,
    play(dt: number) {
      t = (t + dt) % PERIOD;
      drawOrb(g, px / BLOOM, t);
      tex.needsUpdate = true;
    },
  };
}
type Orb = ReturnType<typeof orbTexture>;

/** Homebot's Siri light as a wide soft cloud, for the speaker's halo. */
function haloTexture() {
  const [c, g] = canvas(256, 96);
  g.filter = "blur(16px)";
  const lin = g.createLinearGradient(40, 0, 216, 0);
  lin.addColorStop(0, "#22e6ff");
  lin.addColorStop(0.35, "#2f5bff");
  lin.addColorStop(0.65, "#ff2bd6");
  lin.addColorStop(1, "#ff8a1f");
  g.fillStyle = lin;
  g.beginPath();
  g.ellipse(128, 70, 84, 22, 0, 0, Math.PI * 2);
  g.fill();
  return texture(c);
}

/**
 * The speaker's acoustic mesh: a plain weave of round threads laid on the diagonal, each passing
 * over one and under the next. One height field gives three maps: a normal map (the threads'
 * relief), a roughness map (thread tops a little smoother than the gaps) and a shade map (gaps
 * a little darker), all tiling seamlessly.
 */
function weaveMaps() {
  const s = 256;
  const n = 4; // threads of each direction per tile
  const height = new Float32Array(s * s);
  const frac = (v: number) => v - Math.floor(v);
  // A little per-thread variation, so the cloth isn't machine-perfect.
  const jitter = (i: number) => frac(Math.sin(i * 127.1) * 43758.5) * 0.12;
  for (let y = 0; y < s; y++)
    for (let x = 0; x < s; x++) {
      const u = x / s;
      const v = y / s;
      // Diagonal coordinates; whole thread counts per tile keep the tile seamless.
      const a = (u + v) * n;
      const b = (u - v) * n + n;
      const ia = Math.floor(a);
      const ib = Math.floor(b);
      const fa = frac(a);
      const fb = frac(b);
      // Round thread cross-sections, with a gap between neighbours.
      const prof = (f: number) => Math.max(0, Math.sin(Math.PI * Math.min(1, Math.max(0, (f - 0.08) / 0.84)))) ** 0.6;
      const over = (ia + ib) % 2 === 0;
      // Each thread arches over its crossing and dips under the next.
      const warp = prof(fb) * (over ? 0.78 + 0.22 * Math.sin(Math.PI * fa) : 0.42) * (1 - jitter(ib % n));
      const weft = prof(fa) * (over ? 0.42 : 0.78 + 0.22 * Math.sin(Math.PI * fb)) * (1 - jitter((ia % n) + 31));
      height[y * s + x] = Math.max(warp, weft);
    }
  const [nc, ng] = canvas(s, s);
  const [rc, rg] = canvas(s, s);
  const [cc, cg] = canvas(s, s);
  const ni = ng.createImageData(s, s);
  const ri = rg.createImageData(s, s);
  const ci = cg.createImageData(s, s);
  const h = (x: number, y: number) => height[((y + s) % s) * s + ((x + s) % s)];
  for (let y = 0; y < s; y++)
    for (let x = 0; x < s; x++) {
      const dx = (h(x + 1, y) - h(x - 1, y)) * 3;
      const dy = (h(x, y + 1) - h(x, y - 1)) * 3;
      const len = Math.hypot(dx, dy, 1);
      const i = (y * s + x) * 4;
      ni.data[i] = ((-dx / len) * 0.5 + 0.5) * 255;
      ni.data[i + 1] = ((dy / len) * 0.5 + 0.5) * 255;
      ni.data[i + 2] = ((1 / len) * 0.5 + 0.5) * 255;
      const hv = h(x, y);
      const r = (0.98 - hv * 0.16) * 255;
      const c = (0.62 + hv * 0.38) * 255;
      ri.data[i] = ri.data[i + 1] = ri.data[i + 2] = r;
      ci.data[i] = ci.data[i + 1] = ci.data[i + 2] = c;
      ni.data[i + 3] = ri.data[i + 3] = ci.data[i + 3] = 255;
    }
  ng.putImageData(ni, 0, 0);
  rg.putImageData(ri, 0, 0);
  cg.putImageData(ci, 0, 0);
  const maps = { normal: texture(nc, false), rough: texture(rc, false), shade: texture(cc) };
  for (const t of Object.values(maps)) {
    t.wrapS = t.wrapT = RepeatWrapping;
    t.anisotropy = 8;
  }
  return maps;
}

/** A soft round shadow to set the device down on. */
function shadowMesh(w: number, d: number, strength = 0.32) {
  const [c, g] = canvas(128, 128);
  const r = g.createRadialGradient(64, 64, 0, 64, 64, 64);
  r.addColorStop(0, `rgba(0,0,0,${strength})`);
  r.addColorStop(0.55, `rgba(0,0,0,${strength * 0.45})`);
  r.addColorStop(1, "rgba(0,0,0,0)");
  g.fillStyle = r;
  g.fillRect(0, 0, 128, 128);
  const m = new Mesh(new PlaneGeometry(w, d), new MeshBasicMaterial({ map: texture(c), transparent: true, depthWrite: false }));
  m.rotation.x = -Math.PI / 2;
  return m;
}

function roundRect(g: CanvasRenderingContext2D, x: number, y: number, w: number, h: number, r: number) {
  g.beginPath();
  g.roundRect(x, y, w, h, r);
}

// ---------------------------------------------------------------- HomePod mini-like speaker

function homePod(orb: Orb) {
  const group = new Group();
  // Profile: a sphere cut flat top and bottom (height ≈ 0.86 × width), with soft edges.
  const cut = 0.86;
  const raw: Vector2[] = [];
  const bottomR = Math.sqrt(1 - cut * cut) - 0.06;
  raw.push(new Vector2(0, -cut));
  raw.push(new Vector2(bottomR, -cut));
  const a0 = -Math.asin(cut - 0.02);
  const a1 = Math.asin(cut - 0.02);
  for (let i = 0; i <= 48; i++) {
    const a = a0 + ((a1 - a0) * i) / 48;
    raw.push(new Vector2(Math.cos(a), Math.sin(a)));
  }
  raw.push(new Vector2(bottomR, cut));
  // A shallow well for the glass top.
  const well = bottomR - 0.01;
  raw.push(new Vector2(well, cut));
  raw.push(new Vector2(well, cut - 0.03));
  raw.push(new Vector2(0, cut - 0.03));
  // Acoustic mesh: the weave as relief, roughness and shade, under a soft cloth sheen. About 36
  // threads cross the front at the size shown, a few pixels each: visible, not noisy.
  const weave = weaveMaps();
  for (const t of Object.values(weave)) t.repeat.set(30, 10);
  const fabric = new MeshPhysicalMaterial({
    map: weave.shade,
    normalMap: weave.normal,
    roughnessMap: weave.rough,
    roughness: 1,
    sheen: 1,
    sheenRoughness: 0.45,
  });
  fabric.normalScale.set(1.1, 1.1);
  const body = new Mesh(new LatheGeometry(raw, 128), fabric);
  group.add(body);

  // The top: a glass touch surface set just into the fabric, a dark rim around it, and the light
  // beneath it.
  const topR = well - 0.02;
  const rim = new Mesh(new RingGeometry(topR, well, 64), new MeshStandardMaterial({ color: 0x050506, roughness: 0.6, polygonOffset: true, polygonOffsetFactor: -1 }));
  rim.rotation.x = -Math.PI / 2;
  rim.position.y = cut - 0.003;
  group.add(rim);
  const glass = new MeshPhysicalMaterial({
    color: 0x08080a,
    roughness: 0.35,
    clearcoat: 1,
    clearcoatRoughness: 0.08,
    emissive: 0xffffff,
    emissiveMap: orb.tex,
    emissiveIntensity: 0,
    polygonOffset: true,
    polygonOffsetFactor: -2,
  });
  const top = new Mesh(new CircleGeometry(topR, 64), glass);
  top.rotation.x = -Math.PI / 2;
  top.position.y = cut - 0.012;
  group.add(top);
  // Seen nearly level, the top is a sliver: a soft halo above it carries the light.
  const halo = new Mesh(
    new PlaneGeometry(1.5, 0.36),
    new MeshBasicMaterial({ map: haloTexture(), transparent: true, opacity: 0, blending: AdditiveBlending, depthWrite: false, toneMapped: false }),
  );
  halo.position.set(0, cut + 0.06, 0.2);
  group.add(halo);

  const shadow = shadowMesh(2.2, 2.2, 0.4);
  shadow.position.y = -cut - 0.002;
  group.add(shadow);

  return {
    group,
    // Nearly level: just enough above to see the lit top as a thin ellipse.
    view: { w: 1.08, h: 1.07, cy: 0.03, tilt: 0.12 },
    setDark(dark: boolean) {
      // Light: white cloth. Dark: a deep space-grey with a cool, midnight cast.
      fabric.color = new Color(dark ? 0x3d4049 : 0xf4f5f7);
      fabric.sheenColor = new Color(dark ? 0x8a90a0 : 0xffffff);
    },
    setLit(v: number) {
      // A faint glow at rest, so the glass reads as lit from beneath; full while Siri listens.
      glass.emissiveIntensity = 0.12 + v * 1.5;
      (halo.material as MeshBasicMaterial).opacity = v * 0.75;
    },
    turn(dt: number) {
      orb.play(dt);
    },
    dispose() {},
  };
}

// ---------------------------------------------------------------- Phone

function phone(orb: Orb) {
  const group = new Group();
  const W = 0.716;
  const H = 1.476;
  const D = 0.078;
  const frame = new MeshPhysicalMaterial({ metalness: 1, roughness: 0.32, clearcoat: 0.4 });
  const body = new Mesh(new RoundedBoxGeometry(W, H, D, 6, 0.11), frame);
  group.add(body);

  // The screen: black glass with the island; the orb is a separate disc so it can swirl.
  const [c, g] = canvas(256, 528);
  g.fillStyle = "#000";
  roundRect(g, 0, 0, 256, 528, 34);
  g.fill();
  const wall = g.createLinearGradient(0, 0, 0, 528);
  wall.addColorStop(0, "#14141a");
  wall.addColorStop(1, "#0a0a0e");
  g.fillStyle = wall;
  roundRect(g, 8, 8, 240, 512, 30);
  g.fill();
  g.fillStyle = "#000";
  roundRect(g, 92, 20, 72, 21, 10.5);
  g.fill();
  const screen = new Mesh(
    new PlaneGeometry(W - 0.03, H - 0.03),
    new MeshPhysicalMaterial({ map: texture(c), roughness: 0.08, metalness: 0, clearcoat: 1, transparent: true }),
  );
  screen.position.z = D / 2 + 0.001;
  group.add(screen);

  const orbDisc = new Mesh(new PlaneGeometry(0.24 * BLOOM, 0.24 * BLOOM), new MeshBasicMaterial({ map: orb.tex, transparent: true, opacity: 0, toneMapped: false, depthWrite: false }));
  orbDisc.position.set(0, -0.48, D / 2 + 0.003);
  group.add(orbDisc);

  // Side buttons.
  const button = (y: number, h: number, side: 1 | -1) => {
    const b = new Mesh(new BoxGeometry(0.012, h, 0.03), frame);
    b.position.set((side * W) / 2 + side * 0.004, y, 0);
    group.add(b);
  };
  button(0.36, 0.13, 1);
  button(0.42, 0.06, -1);
  button(0.28, 0.1, -1);
  button(0.15, 0.1, -1);

  return {
    group,
    view: { w: 0.4, h: 0.77, cy: 0, tilt: 0 },
    setDark(dark: boolean) {
      frame.color = new Color(dark ? 0x3c3c3f : 0xc9c4bc);
    },
    setLit(v: number) {
      (orbDisc.material as MeshBasicMaterial).opacity = v;
      orbDisc.scale.setScalar(0.6 + v * 0.4);
    },
    turn(dt: number) {
      orb.play(dt);
    },
    dispose() {},
  };
}

// ---------------------------------------------------------------- Laptop

function laptop() {
  const group = new Group();
  const W = 3.04;
  const Dp = 2.12;
  const metal = new MeshPhysicalMaterial({ metalness: 1, roughness: 0.36 });

  // Base, with the keyboard and trackpad drawn on its top.
  const base = new Mesh(new RoundedBoxGeometry(W + 0.16, 0.09, Dp, 4, 0.04), metal);
  base.position.y = 0.045;
  group.add(base);
  const notch = new Mesh(new PlaneGeometry(0.5, 0.035), new MeshStandardMaterial({ color: 0x000000, transparent: true, opacity: 0.35, roughness: 0.6 }));
  notch.position.set(0, 0.072, Dp / 2 + 0.001);
  group.add(notch);
  const [kc, kg] = canvas(512, 358);
  const deck = new MeshStandardMaterial({ map: texture(kc), metalness: 0.6, roughness: 0.5, transparent: true });
  const drawDeck = (dark: boolean) => {
    kg.clearRect(0, 0, 512, 358);
    kg.fillStyle = dark ? "#0d0d0f" : "#2a2a2d";
    roundRect(kg, 46, 22, 420, 168, 10);
    kg.fill();
    kg.fillStyle = dark ? "#1b1b1e" : "#151517";
    const kw = 420 / 14;
    for (let r = 0; r < 6; r++)
      for (let k = 0; k < 14; k++) {
        roundRect(kg, 46 + k * kw + 2.5, 22 + r * 28 + 3, kw - 5, 22, 4);
        kg.fill();
      }
    kg.fillStyle = dark ? "rgba(255,255,255,0.05)" : "rgba(0,0,0,0.06)";
    roundRect(kg, 166, 206, 180, 124, 10);
    kg.fill();
    deck.map!.needsUpdate = true;
  };
  const top = new Mesh(new PlaneGeometry(W - 0.12, Dp - 0.12), deck);
  top.rotation.x = -Math.PI / 2;
  top.position.y = 0.0902;
  group.add(top);

  // Lid, hinged at the back edge and open a little past upright.
  const lidH = 1.98;
  const hinge = new Group();
  hinge.position.set(0, 0.09, -Dp / 2 + 0.02);
  hinge.rotation.x = 0;
  group.add(hinge);
  const lid = new Mesh(new RoundedBoxGeometry(W, lidH, 0.045, 4, 0.02), metal);
  lid.position.set(0, lidH / 2, 0);
  hinge.add(lid);

  // The display: Homebot's live logo (mark.ts), centred, on a dark desktop.
  const [sc, sg] = canvas(640, 416);
  const screenTex = texture(sc);
  const MARK = 144;
  let mark: MarkState = REST;
  let flow = 0;
  const drawScreen = () => {
    sg.fillStyle = "#000";
    sg.fillRect(0, 0, 640, 416);
    const bg = sg.createRadialGradient(320, 300, 20, 320, 220, 420);
    bg.addColorStop(0, "#1d1b2b");
    bg.addColorStop(1, "#08080c");
    sg.fillStyle = bg;
    roundRect(sg, 14, 14, 612, 388, 14);
    sg.fill();
    sg.fillStyle = "#000";
    roundRect(sg, 282, 14, 76, 16, 6);
    sg.fill();
    drawMark(sg, 320 - MARK / 2, 208 - MARK / 2, MARK, flow, mark);
    screenTex.needsUpdate = true;
  };
  drawScreen();
  const screenMat = new MeshStandardMaterial({ color: 0x000000, roughness: 0.15, emissive: 0xffffff, emissiveMap: screenTex, emissiveIntensity: 0.7 });
  const screen = new Mesh(new PlaneGeometry(W - 0.1, lidH - 0.1), screenMat);
  screen.position.set(0, lidH / 2, 0.0235);
  hinge.add(screen);

  group.position.y = -(lidH + 0.09) / 2;

  return {
    group,
    view: { w: 1.6, h: 1.1, cy: 0, tilt: 0 },
    setDark(on: boolean) {
      metal.color = new Color(on ? 0x3a3b3e : 0xd5d6d9);
      drawDeck(on);
    },
    setLit(v: number) {
      screenMat.emissiveIntensity = 0.55 + v * 0.45;
    },
    turn() {},
    /** The logo on the display: its centre and width in world units, a redraw for a new state,
     *  and the light's flow moved on by `dt` seconds. */
    eyes: {
      centre: () => screen.localToWorld(new Vector3(0, 0, 0)),
      width: (MARK / 640) * (W - 0.1),
      set(s: MarkState) {
        mark = s;
        drawScreen();
      },
      flow(dt: number) {
        flow += dt;
        drawScreen();
      },
    },
    dispose() {},
  };
}

// ---------------------------------------------------------------- Mounting

function build(renderer: WebGLRenderer, kind: DeviceKind, dark: boolean) {
  renderer.setPixelRatio(Math.min(devicePixelRatio, 2));
  renderer.outputColorSpace = SRGBColorSpace;
  renderer.toneMapping = ACESFilmicToneMapping;
  renderer.toneMappingExposure = 1.1;

  const scene = new Scene();
  const pmrem = new PMREMGenerator(renderer);
  const env = pmrem.fromScene(new RoomEnvironment(), 0.04).texture;
  scene.environment = env;
  pmrem.dispose();
  const key = new DirectionalLight(0xffffff, 1.5);
  key.position.set(-2.5, 3.5, 4);
  scene.add(key);
  const rim = new DirectionalLight(0xffffff, 0.9);
  rim.position.set(2, 2.5, -4);
  scene.add(rim);

  if (kind === "homepod") {
    // Studio light raking across the cloth from the side, so the weave catches it; less
    // ambient fill, so the threads' relief doesn't wash out.
    scene.environmentIntensity = 0.7;
    const graze = new DirectionalLight(0xffffff, 1.3);
    graze.position.set(-4, 0.8, 1.4);
    scene.add(graze);
  }

  const orb = orbTexture();
  const model = kind === "homepod" ? homePod(orb) : kind === "iphone" ? phone(orb) : laptop();
  scene.add(model.group);
  model.setDark(dark);

  return { scene, env, model };
}

/** Adds a canvas to host and draws the device in it; null without WebGL. */
export function mountDevice(host: HTMLElement, kind: DeviceKind, opts: { dark: boolean; reduce: boolean }): DeviceHandle | null {
  const cv = document.createElement("canvas");
  cv.className = "absolute inset-0 size-full";
  cv.setAttribute("aria-hidden", "true");
  let renderer: WebGLRenderer;
  try {
    renderer = new WebGLRenderer({ canvas: cv, antialias: true, alpha: true, powerPreference: "low-power" });
  } catch {
    return null;
  }
  host.append(cv);
  let wake = () => {};
  let built: ReturnType<typeof build>;
  try {
    built = build(renderer, kind, opts.dark);
  } catch {
    renderer.dispose();
    renderer.forceContextLoss();
    cv.remove();
    return null;
  }
  const { scene, env, model } = built;
  const { view } = model;
  const camera = new OrthographicCamera(-1, 1, 1, -1, 0.1, 50);
  camera.position.set(0, view.cy + Math.sin(view.tilt) * 10, Math.cos(view.tilt) * 10);
  camera.lookAt(0, view.cy, 0);

  let lit = false;
  let level = 0;
  let reduce = opts.reduce;
  let visible = true;
  let frame = 0;
  let last = 0;

  const size = () => {
    const w = cv.clientWidth || 1;
    const h = cv.clientHeight || 1;
    renderer.setSize(w, h, false);
    // Fit the device's half extents, whichever way the canvas is narrower.
    const half = Math.max(view.h, view.w / (w / h));
    camera.top = half;
    camera.bottom = -half;
    camera.left = -half * (w / h);
    camera.right = half * (w / h);
    camera.updateProjectionMatrix();
  };
  const draw = () => renderer.render(scene, camera);
  // While lit (or fading) and on screen, animate; otherwise one frame per change.
  const tick = (now: number) => {
    frame = 0;
    const dt = last ? Math.min((now - last) / 1000, 0.05) : 0.016;
    last = now;
    const target = lit ? 1 : 0;
    level = reduce ? target : level + (target - level) * Math.min(1, dt * 7);
    if (Math.abs(target - level) < 0.004) level = target;
    model.setLit(level);
    if (!reduce && lit) model.turn(dt);
    draw();
    if (visible && ((lit && !reduce) || level !== target)) frame = requestAnimationFrame(tick);
    else last = 0;
  };
  wake = () => {
    if (!frame) frame = requestAnimationFrame(tick);
  };

  const ro = new ResizeObserver(() => {
    size();
    wake();
  });
  ro.observe(cv);
  const io = new IntersectionObserver(([e]) => {
    visible = e.isIntersecting;
    if (visible) wake();
  });
  io.observe(cv);
  size();
  wake();

  // The Mac's display shows the live logo: its eyes follow the pointer from where the logo is
  // drawn on the page.
  const mark = (model as { eyes?: { centre: () => Vector3; width: number; set: (s: MarkState) => void; flow: (dt: number) => void } }).eyes ?? null;
  // Its light flows at 20 frames a second, only while the logo is live.
  let flowing = 0;
  const life =
    mark &&
    liveMark({
      watch: cv,
      reduce,
      where: () => {
        const r = cv.getBoundingClientRect();
        const c = mark.centre().project(camera);
        const px = (r.width / (camera.right - camera.left)) * mark.width;
        return { x: r.left + ((c.x + 1) / 2) * r.width, y: r.top + ((1 - c.y) / 2) * r.height, size: px };
      },
      draw: (s) => {
        mark.set(s);
        wake();
      },
      onLive: (on) => {
        clearInterval(flowing);
        if (on)
          flowing = window.setInterval(() => {
            mark.flow(0.05);
            wake();
          }, 50);
      },
    });

  return {
    setLit(on) {
      lit = on;
      wake();
    },
    setDark(on) {
      model.setDark(on);
      wake();
    },
    setReduce(on) {
      reduce = on;
      life?.setReduce(on);
      wake();
    },
    dispose() {
      cancelAnimationFrame(frame);
      life?.dispose();
      clearInterval(flowing);
      model.dispose();
      ro.disconnect();
      io.disconnect();
      scene.traverse((o) => {
        if (o instanceof Mesh) {
          o.geometry.dispose();
          const mats: Material[] = Array.isArray(o.material) ? o.material : [o.material];
          for (const m of mats) {
            for (const v of Object.values(m)) if (v && (v as Texture).isTexture) (v as Texture).dispose();
            m.dispose();
          }
        }
      });
      env.dispose();
      renderer.dispose();
      renderer.forceContextLoss();
      cv.remove();
    },
  };
}
