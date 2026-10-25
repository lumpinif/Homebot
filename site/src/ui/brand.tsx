// Homebot's mark, the Grok Bot icon and the Siri orb, as the app draws them
// (web/src/app/brand.tsx). The Grok Bot icon is its App Store artwork, used only to name the
// product; the marks belong to their owners. The Siri orb is Homebot's own drawing, not Apple's:
// the same orb as the app's (orb.ts).
import { useReducedMotion } from "@/lib/reduced-motion";
import { useEffect, useRef } from "react";
import { cn } from "@/lib/utils";
import { EYES_X, eyeRect, FLOW, liveMark, PIVOT, ROOF } from "./mark";
import { BLOOM, drawOrb, PERIOD, STILL } from "./orb";

export const asset = (name: string) => `${import.meta.env.BASE_URL}${name}`;

/**
 * Homebot's logo: the app's mark on a flowing light in the Siri orb's hues and the Glow icon's
 * warmth, alive (mark.ts): the eyes look around, blink and glance, the glyph now and then hops or
 * tilts, and the light breathes; a pointer nearby draws the eyes and lifts the glow. Still under
 * reduced motion. Sized by font size.
 */
export function HomebotLogo({ className }: { className?: string }) {
  const reduce = useReducedMotion();
  const box = useRef<HTMLSpanElement>(null);
  const glyph = useRef<SVGGElement>(null);
  const eyes = useRef<(SVGRectElement | null)[]>([]);
  useEffect(() => {
    const el = box.current;
    if (!el) return;
    const ctl = liveMark({
      watch: el,
      reduce,
      where: () => {
        const r = el.getBoundingClientRect();
        return { x: r.left + r.width / 2, y: r.top + r.height / 2, size: r.width };
      },
      onLive: (on) => el.toggleAttribute("data-live", on),
      draw: (s) => {
        glyph.current?.setAttribute("transform", `translate(0 ${s.hop}) rotate(${s.tilt} ${PIVOT[0]} ${PIVOT[1]})`);
        el.style.setProperty("--lift", `${s.lift}`);
        EYES_X.forEach((x, i) => {
          const e = eyes.current[i];
          if (!e) return;
          const r = eyeRect(x, s.gx, s.gy, s.blink);
          e.setAttribute("x", `${r.x}`);
          e.setAttribute("y", `${r.y}`);
          e.setAttribute("height", `${r.h}`);
          e.setAttribute("rx", `${r.r}`);
        });
      },
    });
    return () => ctl.dispose();
  }, [reduce]);
  return (
    <span ref={box} aria-hidden className={cn("hb-logo text-[32px]", className)}>
      <span className="hb-flow">
        {FLOW.map((c, i) => (
          <i key={c} style={{ background: `radial-gradient(closest-side, ${c}, ${c}99 45%, ${c}00)`, ["--i" as string]: i }} />
        ))}
      </span>
      <span className="hb-breath" />
      <svg viewBox="5 5 54 54">
        <g ref={glyph} fill="#fff">
          <path d={ROOF} fill="none" stroke="#fff" strokeWidth="4.6" strokeLinecap="round" strokeLinejoin="round" />
          {EYES_X.map((x, i) => (
            <rect key={x} ref={(e) => void (eyes.current[i] = e)} x={x} y="34.5" width="5.4" height="11" rx="2.7" />
          ))}
        </g>
      </svg>
    </span>
  );
}

export function GrokBotAvatar({ className }: { className?: string }) {
  return (
    <img
      src={asset("grok-bot.png")}
      alt=""
      aria-hidden
      draggable={false}
      className={cn("inline-block size-[0.92em] rounded-[22.5%] shadow-sm ring-1 ring-black/10 select-none dark:ring-white/15", className)}
    />
  );
}

/** Every orb on the page draws on one clock, at 30 frames a second, only while it is on screen. */
type Live = { draw: (t: number) => void; live: () => boolean };
const orbs = new Set<Live>();
let raf = 0;
let last = 0;
const start = performance.now();
function tick(now: number) {
  raf = 0;
  const live = [...orbs].filter((o) => o.live());
  if (!live.length) return;
  if (now - last >= 1000 / 30) {
    last = now;
    const t = ((now - start) / 1000) % PERIOD;
    for (const o of live) o.draw(t);
  }
  raf = requestAnimationFrame(tick);
}
const kick = () => {
  if (!raf) raf = requestAnimationFrame(tick);
};

/** The app's Siri orb (orb.ts). Its glow spills past the box, as in the app; the box sets the size. */
export function SiriOrb({ className, active = true }: { className?: string; active?: boolean }) {
  const reduce = useReducedMotion();
  const box = useRef<HTMLSpanElement>(null);
  const cv = useRef<HTMLCanvasElement>(null);
  const state = useRef({ live: false, visible: true, size: 0, scale: 1 });
  state.current.live = active && !reduce;

  useEffect(() => {
    const el = box.current!;
    const c = cv.current!;
    const g = c.getContext("2d");
    if (!g) return;
    const st = state.current;
    const draw = (t: number) => drawOrb(g, st.size * st.scale, t);
    const fit = () => {
      st.size = el.clientWidth;
      // Small orbs are drawn finer than the screen and filtered down, as the app does.
      st.scale = Math.min(devicePixelRatio || 1, 2) * (st.size <= 32 ? 2 : 1);
      c.width = c.height = Math.ceil(st.size * BLOOM * st.scale);
      draw(STILL);
    };
    const me: Live = { draw, live: () => st.live && st.visible && st.size > 0 };
    orbs.add(me);
    const ro = new ResizeObserver(() => {
      fit();
      kick();
    });
    ro.observe(el);
    const io = new IntersectionObserver(([e]) => {
      st.visible = e.isIntersecting;
      kick();
    });
    io.observe(el);
    return () => {
      orbs.delete(me);
      ro.disconnect();
      io.disconnect();
    };
  }, []);

  useEffect(() => {
    if (state.current.live) kick();
  }, [active, reduce]);

  return (
    <span ref={box} aria-hidden className={cn("relative inline-block size-7 shrink-0", className)}>
      <canvas ref={cv} className="pointer-events-none absolute -inset-1/4 size-[150%] max-w-none" />
    </span>
  );
}
