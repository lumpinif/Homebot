// How one question travels: Siri on the HomePod or iPhone runs the Shortcut, the Shortcut asks
// Homebot on the Mac over home Wi-Fi, Homebot asks the Grok Bot over the internet, and the
// reply comes back the same way for Siri to read aloud. Plays on its own while visible; each
// stage can be picked. With reduced motion nothing moves by itself and packets jump.
import { animate, AnimatePresence, motion, useInView, useMotionValue } from "motion/react";
import { useReducedMotion } from "@/lib/reduced-motion";
import { useEffect, useRef, useState, type ReactNode } from "react";
import { MessageCircle, Pause, Play } from "lucide-react";
import { cn } from "@/lib/utils";
import { useT } from "@/i18n";
import { hey, siriLang } from "@/spoken";
import { GrokBotAvatar, HomebotLogo, SiriOrb } from "@/ui/brand";
import { Segmented } from "@/ui/kit";
import { CarouselDots } from "@/ui/ff/carousel-dots";
import { Device3D, preloadDevices } from "@/ui/devices3d";

type Packet = "q1" | "q2" | "a2" | "a1" | null;
type Beat = { stage: 0 | 1 | 2 | 3; lines: number; packet: Packet; thinking?: boolean; ms: number };

const BEATS: Beat[] = [
  { stage: 0, lines: 1, packet: null, ms: 1100 },
  { stage: 0, lines: 2, packet: null, ms: 1300 },
  { stage: 0, lines: 3, packet: null, ms: 1000 },
  { stage: 1, lines: 3, packet: "q1", ms: 1300 },
  { stage: 2, lines: 3, packet: "q2", ms: 1300 },
  { stage: 2, lines: 3, packet: null, thinking: true, ms: 1300 },
  { stage: 2, lines: 3, packet: "a2", ms: 1200 },
  { stage: 3, lines: 3, packet: "a1", ms: 1200 },
  { stage: 3, lines: 4, packet: null, ms: 3800 },
];
const FIRST_OF_STAGE = [0, 3, 4, 7];
const LAST = BEATS.length - 1;

export function Flow() {
  const { t, lang } = useT();
  const reduce = useReducedMotion();
  const ref = useRef<HTMLDivElement>(null);
  const visible = useInView(ref, { amount: 0.4 });
  const [device, setDevice] = useState<"homepod" | "iphone">("homepod");
  useEffect(() => {
    preloadDevices().catch(() => {});
  }, []);
  const [beat, setBeat] = useState(reduce ? LAST : 0);
  const [playing, setPlaying] = useState(!reduce);

  // Turning on Reduce Motion mid-play stops it on the last frame.
  useEffect(() => {
    if (!reduce) return;
    setPlaying(false);
    setBeat(LAST);
  }, [reduce]);

  useEffect(() => {
    if (!playing || !visible || reduce) return;
    const id = setTimeout(() => setBeat((b) => (b + 1) % BEATS.length), BEATS[beat].ms);
    return () => clearTimeout(id);
  }, [beat, playing, visible, reduce]);

  // How far the current stage has played, 0 to 1: each beat glides it on to where that beat ends.
  const progress = useMotionValue(0);
  useEffect(() => {
    const stage = BEATS[beat].stage;
    const first = FIRST_OF_STAGE[stage];
    const total = BEATS.filter((x) => x.stage === stage).reduce((n, x) => n + x.ms, 0);
    const before = BEATS.slice(first, beat).reduce((n, x) => n + x.ms, 0);
    const from = before / total;
    const to = (before + BEATS[beat].ms) / total;
    if (progress.get() > to || progress.get() < from) progress.set(from);
    if (!playing || !visible || reduce) return;
    const ctl = animate(progress, to, { duration: ((to - progress.get()) * total) / 1000, ease: "linear" });
    return () => ctl.stop();
  }, [beat, playing, visible, reduce, progress]);

  // Apple doesn't list Portuguese (Brazil) or Korean as HomePod Siri languages: show the iPhone.
  const homePodSiri = lang !== "pt-BR" && lang !== "ko";
  const shown = homePodSiri ? device : "iphone";
  const b = BEATS[beat];
  // The sample exchange is in the page's language, with the app's own wake phrase and question.
  const sl = siriLang(lang);
  const wake = hey(sl, sl.phrases[0]);
  const ask = sl.prompt(t.sampleBot);
  const lines: { who: "you" | "siri"; text: string }[] = [
    { who: "you", text: wake },
    { who: "siri", text: ask },
    { who: "you", text: t.sampleQ },
    { who: "siri", text: t.sampleA },
  ];

  const stages = [t.stage1, t.stage2, t.stage3, t.stage4];
  const listening = b.stage === 0;
  const speaking = beat === LAST;

  return (
    <div ref={ref} className="flex flex-col items-center">
      {homePodSiri && (
        <Segmented
          label={t.device}
          value={device}
          onChange={(d) => {
            // Another device: the same question again from the start.
            setDevice(d);
            setBeat(reduce ? LAST : 0);
            if (!reduce) setPlaying(true);
          }}
          options={[
            { value: "homepod", label: t.homePod },
            { value: "iphone", label: t.iPhone },
          ]}
        />
      )}

      {/* The three nodes and the two links between them. */}
      <div className="mt-10 flex w-full items-start" aria-hidden>
        <Node label={shown === "homepod" ? t.homePod : t.iPhone} active={listening || speaking}>
          {/* Both stay loaded; switching cross-fades between them. */}
          <div className="relative size-[76px] sm:size-[108px]">
            {(["homepod", "iphone"] as const).map((d) => (
              <div key={d} className={cn("absolute inset-0 transition-opacity duration-300", shown === d ? "opacity-100" : "opacity-0")}>
                <Device3D
                  kind={d}
                  lit={shown === d && (listening || speaking)}
                  fallback={d === "homepod" ? <HomePod lit={listening || speaking} /> : <IPhone lit={listening || speaking} />}
                  className="size-full"
                />
              </div>
            ))}
          </div>
        </Node>
        <Link label={t.homeWifi} active={b.packet === "q1" || b.packet === "a1"} packet={b.packet === "q1" ? "fwd" : b.packet === "a1" ? "back" : null} reduce={!!reduce} />
        <Node label={t.yourMac} active={b.stage === 1 || b.packet === "q2" || b.packet === "a2" || b.packet === "a1"}>
          <Device3D kind="mac" lit={b.stage === 1 || b.stage === 2 || b.packet === "a1"} fallback={<Mac active={b.stage === 1 || b.stage === 2 || b.packet === "a1"} />} className="h-[76px] w-[76px] sm:h-[108px] sm:w-[124px]" />
        </Node>
        <Link label={t.internet} active={b.packet === "q2" || b.packet === "a2"} packet={b.packet === "q2" ? "fwd" : b.packet === "a2" ? "back" : null} reduce={!!reduce} />
        <Node label={t.grokBot} active={b.stage === 2}>
          <div className="relative">
            <GrokBotAvatar className="size-[56px] sm:size-[64px]" />
            <AnimatePresence>{b.thinking && <Thinking />}</AnimatePresence>
          </div>
        </Node>
      </div>

      {/* What is said, in order: fixed height so nothing below moves. */}
      <div className="mt-16 flex h-[248px] w-full flex-col justify-start gap-2 lg:h-[196px]" aria-live={playing ? "off" : "polite"}>
        <AnimatePresence initial={false}>
          {lines.slice(0, b.lines).map((l, i) => (
            <motion.div
              key={`${i}-${l.text}`}
              layout={!reduce}
              initial={reduce ? { opacity: 0 } : { opacity: 0, y: 10, scale: 0.98 }}
              animate={{ opacity: 1, y: 0, scale: 1 }}
              exit={{ opacity: 0 }}
              transition={{ duration: 0.28, ease: [0.2, 0.8, 0.2, 1] }}
              className={cn("flex items-end gap-2", l.who === "you" ? "justify-end" : "justify-start")}
            >
              {l.who === "siri" && <SiriOrb className="size-6" active={i === 3 ? speaking : listening} />}
              <span
                className={cn(
                  "max-w-[85%] rounded-[18px] px-3.5 py-2 text-[15px] leading-snug",
                  l.who === "you" ? "rounded-br-[6px] bg-accent-fill text-white" : "rounded-bl-[6px] bg-fill-2 text-label",
                )}
              >
                {l.text}
              </span>
            </motion.div>
          ))}
        </AnimatePresence>
      </div>

      {/* The four stages as Fluid Functionalism's dots: the current one fills as its stage
          plays, a click jumps to a stage, and one short caption says what is happening. */}
      <div className="mt-14 flex flex-col items-center gap-2">
        <div className="flex items-center gap-1">
          <button
            onClick={() => {
              if (beat === LAST && !playing) setBeat(0);
              setPlaying((p) => !p);
            }}
            aria-label={playing ? t.pause : t.play}
            className="grid size-[30px] place-items-center rounded-full text-label-2 transition-colors hover:bg-fill-hover hover:text-label"
          >
            {playing ? <Pause className="size-3" fill="currentColor" strokeWidth={0} /> : <Play className="size-3 translate-x-[0.5px]" fill="currentColor" strokeWidth={0} />}
          </button>
          <CarouselDots
            count={4}
            value={b.stage}
            onValueChange={(i) => {
              // Autoplay belongs to the beats; a call here is always a click.
              setBeat(reduce ? (i === 3 ? LAST : i === 0 ? 2 : FIRST_OF_STAGE[i]) : FIRST_OF_STAGE[i]);
            }}
            progress={reduce ? undefined : progress}
            label={t.stages}
            getLabel={(i) => stages[i]}
          />
        </div>
        <p aria-live={playing ? "off" : "polite"} className="text-[14px] text-label-2">
          {stages[b.stage]}
        </p>
      </div>
    </div>
  );
}

function Node({ label, active, children }: { label: string; active: boolean; children: ReactNode }) {
  return (
    <div className="flex w-[76px] shrink-0 flex-col items-center gap-3 sm:w-[124px]">
      <div className="grid h-[100px] place-items-center sm:h-[108px]">{children}</div>
      <span className={cn("text-[12px] whitespace-nowrap transition-colors sm:text-[13px]", active ? "text-label" : "text-label-2")}>{label}</span>
    </div>
  );
}

function Link({ label, active, packet, reduce }: { label: string; active: boolean; packet: "fwd" | "back" | null; reduce: boolean }) {
  return (
    <div className="relative mt-[49px] flex min-w-0 sm:mt-[53px] flex-1 flex-col items-center gap-2">
      <div className="relative h-[2px] w-full">
        <span className="absolute inset-0 bg-[repeating-linear-gradient(90deg,var(--separator)_0_4px,transparent_4px_8px)]" />
        <span className={cn("absolute inset-0 rounded-full bg-accent-fill transition-opacity duration-300", active ? "opacity-60" : "opacity-0")} />
        <AnimatePresence>
          {packet && (
            <motion.span
              key={packet}
              className={cn(
                "absolute top-1/2 grid size-[22px] -translate-x-1/2 -translate-y-1/2 place-items-center rounded-full text-white shadow-[0_2px_8px_rgb(0_0_0/0.2)]",
                packet === "fwd" ? "bg-accent-fill" : "siri-light",
              )}
              initial={{ left: reduce ? (packet === "fwd" ? "100%" : "0%") : packet === "fwd" ? "0%" : "100%", opacity: 0 }}
              animate={{ left: packet === "fwd" ? "100%" : "0%", opacity: 1 }}
              exit={{ opacity: 0 }}
              transition={{ left: { duration: reduce ? 0 : 1.1, ease: [0.45, 0, 0.25, 1] }, opacity: { duration: 0.15 } }}
            >
              {packet === "fwd" ? <MessageCircle className="size-[12px]" strokeWidth={2.6} /> : <Wave />}
            </motion.span>
          )}
        </AnimatePresence>
      </div>
      <span className="text-[11px] whitespace-nowrap text-label-3 max-sm:hidden">{label}</span>
    </div>
  );
}

function Wave() {
  return (
    <svg viewBox="0 0 12 12" className="size-[12px]" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round">
      <path d="M2 5v2M4.5 3.5v5M7 2v8M9.5 4v4" />
    </svg>
  );
}

function Thinking() {
  return (
    <motion.span initial={{ opacity: 0 }} animate={{ opacity: 1 }} exit={{ opacity: 0 }} className="absolute -top-3 -right-3 flex gap-[3px] rounded-full bg-canvas px-2 py-1.5 shadow-[0_1px_4px_rgb(0_0_0/0.15)]">
      {[0, 1, 2].map((i) => (
        <motion.span
          key={i}
          className="size-[5px] rounded-full bg-label-2"
          animate={{ opacity: [0.3, 1, 0.3] }}
          transition={{ duration: 0.9, repeat: Infinity, delay: i * 0.15 }}
        />
      ))}
    </motion.span>
  );
}

/** A HomePod mini-like speaker, drawn plainly: fabric body and a top that lights while Siri is on. */
function HomePod({ lit }: { lit: boolean }) {
  return (
    <div className="relative h-[66px] w-[70px] sm:h-[74px] sm:w-[80px]">
      <div className="absolute inset-0 rounded-[46%/52%] bg-[radial-gradient(circle_at_50%_30%,#f4f4f6,#d7d7dc_70%)] shadow-[inset_0_-6px_10px_rgb(0_0_0/0.08),0_6px_14px_-6px_rgb(0_0_0/0.3)] dark:bg-[radial-gradient(circle_at_50%_30%,#4a4a4e,#26262a_70%)]">
        <div className="absolute inset-0 rounded-[inherit] bg-[radial-gradient(rgb(0_0_0/0.09)_0.8px,transparent_1px)] bg-[length:4px_4px] dark:bg-[radial-gradient(rgb(255_255_255/0.06)_0.8px,transparent_1px)]" />
      </div>
      <div className="absolute top-[6px] left-1/2 h-[14px] w-[44px] -translate-x-1/2 overflow-hidden rounded-[50%] bg-black/80">
        <motion.div className="absolute inset-0 grid place-items-center" animate={{ opacity: lit ? 1 : 0 }} transition={{ duration: 0.3 }}>
          <SiriOrb className="size-[12px]" active={lit} />
        </motion.div>
      </div>
    </div>
  );
}

function IPhone({ lit }: { lit: boolean }) {
  return (
    <div className="relative h-[92px] w-[46px] rounded-[12px] border-[2.5px] border-label/80 bg-canvas p-[3px]">
      <div className="mx-auto h-[5px] w-[16px] rounded-full bg-label/80" />
      <motion.div className="absolute bottom-[8px] left-1/2 -translate-x-1/2" animate={{ opacity: lit ? 1 : 0, scale: lit ? 1 : 0.6 }} transition={{ duration: 0.3 }}>
        <SiriOrb className="size-[18px]" active={lit} />
      </motion.div>
    </div>
  );
}

function Mac({ active }: { active: boolean }) {
  return (
    <div className="flex flex-col items-center">
      <div className={cn("grid h-[58px] w-[84px] place-items-center rounded-t-[7px] border-[2.5px] border-b-0 border-label/80 bg-[#111] transition-shadow duration-300 sm:h-[62px] sm:w-[92px]", active && "shadow-[0_0_0_4px_var(--accent-soft)]")}>
        <HomebotLogo className="text-[26px]" />
      </div>
      <div className="h-[6px] w-[100px] rounded-b-[6px] bg-label/60 sm:w-[110px]" />
    </div>
  );
}
