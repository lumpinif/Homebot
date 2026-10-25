// Brand marks and the two animated avatars.
// The Cursor path comes from @lobehub/icons (MIT, LobeHub); the Grok Bot icon is its official
// App Store artwork. The marks belong to xAI and to Anysphere (Cursor); Homebot uses
// them only to name those products.
// Apple publishes no licensed Siri icon, so the Siri orb and the glow are Homebot's own
// drawing. Colours and layering follow the Apple Intelligence light as open reconstructions
// describe it (see .siri-light in index.css): four hues that blend cleanly, a sharp core under
// a softer drifting layer, slow continuous motion. No random re-shuffles: at icon size they
// read as flicker.
import { motion, useReducedMotion } from "motion/react";
import { cn } from "@/lib/utils";

const CURSOR =
  "M22.106 5.68L12.5.135a.998.998 0 00-.998 0L1.893 5.68a.84.84 0 00-.419.726v11.186c0 .3.16.577.42.727l9.607 5.547a.999.999 0 00.998 0l9.608-5.547a.84.84 0 00.42-.727V6.407a.84.84 0 00-.42-.726zm-.603 1.176L12.228 22.92c-.063.108-.228.064-.228-.061V12.34a.59.59 0 00-.295-.51l-9.11-5.26c-.107-.062-.063-.228.062-.228h18.55c.264 0 .428.286.296.514z";

export function CursorMark({ className }: { className?: string }) {
  return (
    <svg viewBox="0 0 24 24" fill="currentColor" fillRule="evenodd" aria-hidden className={className}>
      <path d={CURSOR} />
    </svg>
  );
}

// Eye offsets in the mark's 64-unit grid: rest, glance left, right, back, up, a little hop down.
const GAZE = {
  x: [0, 0, -3, -3, 3, 3, 0, 0, 0, 0, 0, 0],
  y: [0, 0, 0, 0, 0, 0, 0, -2.2, -2.2, 1.6, 0, 0],
  t: [0, 0.18, 0.22, 0.34, 0.38, 0.5, 0.54, 0.66, 0.74, 0.78, 0.82, 1],
};

/**
 * Homebot's mark: a roofline (home) over two eyes (bot) on a plain black rounded square. Siri's
 * light rises softly from the bottom edge, the way the Siri glow enters when you speak. Sized
 * by font size (1em). When animated, the light turns slowly and the eyes glance and blink.
 * web/public/favicon.svg is the same drawing, still.
 */
export function HomebotMark({ className, still = false }: { className?: string; still?: boolean }) {
  const reduce = useReducedMotion();
  const live = !reduce && !still;
  return (
    <span aria-hidden className={cn("relative isolate inline-block size-[1em] shrink-0 overflow-hidden rounded-[22.37%] bg-black text-[32px]", className)}>
      <span className="mark-light absolute inset-0">
        <motion.span
          className="siri-light absolute inset-[-40%] rounded-full opacity-90 blur-[0.08em]"
          animate={live ? { rotate: 360 } : undefined}
          transition={{ duration: 12, repeat: Infinity, ease: "linear" }}
        />
      </span>
      <svg viewBox="5 5 54 54" className="absolute inset-0 size-full">
        <path d="M17 31 32 19l15 12" fill="none" stroke="#fff" strokeWidth="4.6" strokeLinecap="round" strokeLinejoin="round" />
        {/* Gaze: quick glances left, right, up and down with pauses between (9 s loop); the
            blink runs on its own 6 s loop, so the two rarely line up the same way twice. */}
        <motion.g
          animate={live ? { x: GAZE.x, y: GAZE.y } : undefined}
          transition={{ duration: 9, times: GAZE.t, repeat: Infinity, ease: "easeInOut" }}
        >
          <motion.g
            fill="#fff"
            style={{ transformOrigin: "32px 40px" }}
            animate={live ? { scaleY: [1, 1, 0.15, 1, 1] } : undefined}
            transition={{ duration: 6, times: [0, 0.9, 0.93, 0.96, 1], repeat: Infinity, ease: "easeInOut" }}
          >
            <rect x="23.3" y="34.5" width="5.4" height="11" rx="2.7" />
            <rect x="35.3" y="34.5" width="5.4" height="11" rx="2.7" />
          </motion.g>
        </motion.g>
      </svg>
      <span className="absolute inset-0 rounded-[inherit] ring-1 ring-white/12 ring-inset" />
    </span>
  );
}

/**
 * Grok Bot's official app icon (App Store artwork, 192 px, served as /grok-bot.png), on Apple's
 * rounded-square mask. Now and then it tilts as if looking around.
 */
export function GrokBotAvatar({ className, still = false }: { className?: string; still?: boolean }) {
  const reduce = useReducedMotion();
  return (
    <motion.img
      src="/grok-bot.png"
      alt=""
      aria-hidden
      draggable={false}
      animate={reduce || still ? undefined : { rotate: [0, 0, -8, 5, 0] }}
      transition={{ duration: 5, times: [0, 0.7, 0.8, 0.9, 1], repeat: Infinity, ease: "easeInOut" }}
      className={cn("inline-block size-[0.92em] rounded-[22.5%] align-[-0.108em] shadow-sm ring-1 ring-black/10 select-none dark:ring-white/15", className)}
    />
  );
}

/**
 * The Siri orb: a sharp turning core, a softer layer drifting the other way, and a bright
 * centre. clip-path keeps the light inside the circle even while a parent animates blur or
 * transform (rounded overflow clipping alone lets it show as a square for a few frames).
 */
export function SiriOrb({ className, active = true }: { className?: string; active?: boolean }) {
  const reduce = useReducedMotion();
  const live = !reduce && active;
  return (
    <span aria-hidden className={cn("relative isolate inline-block size-7 shrink-0 overflow-hidden rounded-full bg-black [clip-path:circle(50%)]", className)}>
      <motion.span
        className="siri-light absolute inset-0 rounded-full"
        animate={live ? { rotate: 360 } : undefined}
        transition={{ duration: 11, repeat: Infinity, ease: "linear" }}
      />
      <motion.span
        className="siri-light absolute inset-0 rounded-full opacity-65 mix-blend-screen blur-[0.06em]"
        initial={{ rotate: 140 }}
        animate={live ? { rotate: 140 - 360 } : undefined}
        transition={{ duration: 17, repeat: Infinity, ease: "linear" }}
      />
      <span className="siri-core absolute inset-0 rounded-full" />
      <span className="absolute inset-0 rounded-full ring-1 ring-black/10 ring-inset dark:ring-white/20" />
    </span>
  );
}
