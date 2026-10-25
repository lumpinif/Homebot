// Install: the download, the first open (Homebot is ad-hoc signed and not notarized, so macOS
// blocks it once; four pictures show the way through, no Terminal), the four steps in the app,
// and what it needs.
import { motion, useInView } from "motion/react";
import { useReducedMotion } from "@/lib/reduced-motion";
import { useEffect, useRef, useState, type ReactNode } from "react";
import { ArrowDownToLine, ArrowRight, Laptop, Lock, Speaker, Wifi } from "lucide-react";
import { cn } from "@/lib/utils";
import { useT } from "@/i18n";
import { downloadUrl, REPO_URL } from "@/state";
import { HomebotLogo } from "@/ui/brand";
import { AgentPrompt } from "@/ui/agent";
import { Check } from "@/ui/kit";
import { Heading, TextLink } from "./home";

export function InstallView() {
  const { t, lang } = useT();
  const reduce = useReducedMotion();
  const ref = useRef<HTMLDivElement>(null);
  const visible = useInView(ref, { amount: 0.3 });
  const [step, setStep] = useState(0);
  const [auto, setAuto] = useState(true);
  useEffect(() => {
    if (!auto || !visible || reduce) return;
    const id = setTimeout(() => setStep((s) => (s + 1) % 4), 2600);
    return () => clearTimeout(id);
  }, [step, auto, visible, reduce]);

  const guide = `${REPO_URL}/blob/main/docs/${lang === "zh-Hans" ? "INSTALL.zh-Hans.md" : "INSTALL.md"}`;
  const frames: { caption: string; art: (on: boolean) => ReactNode }[] = [
    { caption: t.guide1, art: (on) => <DragArt on={on} /> },
    { caption: t.guide2, art: (on) => <AlertArt on={on} /> },
    { caption: t.guide3, art: (on) => <SettingsArt on={on} /> },
    { caption: t.guide4, art: (on) => <OpenArt on={on} /> },
  ];
  const inApp = [
    [t.app1, t.app1Note],
    [t.app2, t.app2Note],
    [t.app3, t.app3Note],
    [t.app4, t.app4Note],
  ];
  const needs: [ReactNode, string][] = [
    [<Laptop key="m" className="size-[22px]" strokeWidth={1.7} />, t.needAwake],
    [<Wifi key="w" className="size-[22px]" strokeWidth={1.7} />, t.needWifi],
    [<Speaker key="h" className="size-[22px]" strokeWidth={1.7} />, t.needHomePod],
  ];

  return (
    <div className="flex flex-col gap-32 pt-14 sm:gap-36 sm:pt-20">
      <section className="flex flex-col items-center text-center">
        <HomebotLogo className="text-[120px] shadow-[0_18px_40px_-14px_rgb(0_0_0/0.5)]" />
        <h1 className="mt-8 text-[40px] leading-[1.08] font-bold tracking-[-0.03em] sm:text-[48px]">{t.installTitle}</h1>
        <a
          href={downloadUrl("install")}
          className="mt-8 inline-flex h-11 items-center gap-2 rounded-full bg-accent-fill px-6 text-[16px] font-medium text-white transition-colors hover:bg-[color-mix(in_srgb,var(--accent-fill),black_10%)]"
        >
          <ArrowDownToLine className="size-[18px]" strokeWidth={2.2} />
          {t.download}
        </a>
        <p className="mt-5 text-[13px] text-label-3">{t.installMeta}</p>
        <p className="mt-3 rounded-full bg-fill-2 px-3 py-1 text-[12px] text-label-2">{t.version.replace("{v}", __HOMEBOT_VERSION__)}</p>
      </section>

      <section ref={ref} aria-labelledby="first" className="flex flex-col items-center">
        <Heading id="first" title={t.firstOpen} sub={t.notNotarized} />
        <ol className="mt-14 grid w-full gap-3 sm:grid-cols-2">
          {frames.map((f, i) => {
            const on = reduce ? true : step === i;
            return (
              <li key={i}>
                <button
                  onClick={() => {
                    setAuto(false);
                    setStep(i);
                  }}
                  aria-current={step === i ? "step" : undefined}
                  className={cn("group flex w-full flex-col overflow-hidden rounded-[20px] text-left transition-colors", step === i ? "bg-fill-2" : "bg-fill hover:bg-fill-2")}
                >
                  <div className="grid h-[170px] place-items-center px-3 sm:h-[190px]">{f.art(on)}</div>
                  <div className="flex items-center gap-2.5 px-5 pb-4">
                    <span className={cn("grid size-[22px] shrink-0 place-items-center rounded-full text-[12px] font-semibold tabular-nums transition-colors", step === i ? "bg-accent-fill text-white" : "bg-fill-2 text-label-2")}>
                      {i + 1}
                    </span>
                    <span className="text-[15px] text-label">{f.caption}</span>
                  </div>
                </button>
              </li>
            );
          })}
        </ol>
        <p className="mt-8 text-[15px] text-label-2">{t.everyUpdate}</p>
        <div className="mt-3">
          <TextLink href={guide}>{t.fullGuide}</TextLink>
        </div>
        {/* The agent route right after the hand-held one, as on Home. */}
        <div className="mt-20 w-full">
          <AgentPrompt />
        </div>
      </section>

      <section aria-labelledby="inapp" className="flex flex-col items-center">
        <Heading id="inapp" title={t.inAppTitle} />
        <ol className="mt-14 grid w-full gap-x-10 gap-y-10 sm:grid-cols-2">
          {inApp.map(([title, note], i) => (
            <li key={i} className="flex gap-4">
              <span className="w-7 shrink-0 text-[28px] leading-[1.05] font-semibold tracking-[-0.03em] text-label-3 tabular-nums">{i + 1}</span>
              <span className="flex flex-col gap-1">
                <span className="text-[19px] font-semibold">{title}</span>
                <span className="text-[15px] text-label-2">{note}</span>
              </span>
            </li>
          ))}
        </ol>
      </section>

      <section aria-labelledby="needs" className="flex flex-col items-center">
        <Heading id="needs" title={t.needsTitle} />
        <ul className="mt-14 grid w-full gap-10 sm:grid-cols-3 sm:gap-8">
          {needs.map(([icon, text], i) => (
            <li key={i} className="flex flex-col items-center gap-3 text-center">
              <span className="text-accent">{icon}</span>
              <span className="text-[17px] text-balance">{text}</span>
            </li>
          ))}
        </ul>
      </section>

    </div>
  );
}

/** The highlight on the thing to click: an accent ring that breathes while its frame is current. */
function Target({ on, children, className }: { on: boolean; children: ReactNode; className?: string }) {
  const reduce = useReducedMotion();
  return (
    <span className={cn("relative inline-flex", className)}>
      {children}
      {on && (
        <motion.span
          className="pointer-events-none absolute -inset-[3px] rounded-[9px] ring-2 ring-accent"
          initial={{ opacity: 0 }}
          animate={reduce ? { opacity: 1 } : { opacity: [0.4, 1, 0.4] }}
          transition={{ duration: 1.4, repeat: reduce ? 0 : Infinity }}
        />
      )}
    </span>
  );
}

function DragArt({ on }: { on: boolean }) {
  const { t } = useT();
  const reduce = useReducedMotion();
  return (
    <div className="flex items-center gap-3">
      <motion.span animate={on && !reduce ? { x: [0, 0, 26, 26], opacity: [1, 1, 0.2, 1], scale: [1, 1, 0.8, 1] } : { x: 0 }} transition={{ duration: 2.4, times: [0, 0.3, 0.7, 1] }}>
        <HomebotLogo className="text-[44px]" />
      </motion.span>
      <ArrowRight className="size-5 text-label-3" strokeWidth={2} />
      <span className="flex flex-col items-center gap-1">
        <span className="relative grid h-[44px] w-[54px] place-items-center rounded-[7px] bg-[linear-gradient(180deg,#6cb8ff,#3a8ee8)] text-[17px] font-bold text-white/90 shadow-sm">
          <span className="absolute -top-[5px] left-[4px] h-[8px] w-[20px] rounded-t-[4px] bg-[#5aa9f5]" />
          A
        </span>
        <span className="text-[10px] text-label-2">{t.applications}</span>
      </span>
    </div>
  );
}

function AlertArt({ on }: { on: boolean }) {
  const { t } = useT();
  return (
    <div className="flex w-[170px] flex-col items-center gap-2 rounded-[14px] bg-canvas p-3 text-center shadow-[0_6px_20px_-6px_rgb(0_0_0/0.3),0_0_0_0.5px_rgb(0_0_0/0.08)] sm:w-[190px]">
      <HomebotLogo className="text-[26px]" />
      <span className="text-[11px] leading-tight font-semibold">{t.notOpened}</span>
      <span className="flex w-full flex-col gap-1.5">
        <Target on={on} className="w-full">
          <span className="block w-full rounded-[6px] bg-accent-fill py-1 text-[11px] text-white">{t.done}</span>
        </Target>
        <span className="block w-full rounded-[6px] bg-fill-2 py-1 text-[11px] text-label">{t.moveToTrash}</span>
      </span>
    </div>
  );
}

function SettingsArt({ on }: { on: boolean }) {
  const { t } = useT();
  return (
    <div className="flex h-[118px] w-[200px] overflow-hidden rounded-[12px] bg-canvas shadow-[0_6px_20px_-6px_rgb(0_0_0/0.3),0_0_0_0.5px_rgb(0_0_0/0.08)] sm:w-[230px]">
      <div className="flex w-[64px] shrink-0 flex-col gap-1 bg-fill-2 p-1.5 pt-3">
        <span className="h-1.5 w-8 rounded-full bg-label-3/50" />
        <span className="h-1.5 w-10 rounded-full bg-label-3/50" />
        <span className="flex items-center gap-1 rounded-[4px] bg-accent-fill px-1 py-0.5 text-[7px] leading-tight text-white">
          <Lock className="size-2 shrink-0" strokeWidth={3} />
          <span className="truncate">{t.privacySettings}</span>
        </span>
        <span className="h-1.5 w-9 rounded-full bg-label-3/50" />
      </div>
      <div className="flex min-w-0 flex-1 flex-col gap-1.5 p-2.5">
        <span className="text-[9px] font-semibold text-label-2">{t.security}</span>
        <span className="text-[9px] leading-snug text-label">{t.blockedLine}</span>
        <Target on={on} className="mt-auto self-end">
          <span className="rounded-[6px] bg-fill-2 px-2 py-1 text-[10px] text-label">{t.openAnyway}</span>
        </Target>
      </div>
    </div>
  );
}

function OpenArt({ on }: { on: boolean }) {
  const reduce = useReducedMotion();
  return (
    <div className="relative">
      <motion.span className="block" animate={on && !reduce ? { y: [0, -10, 0, -5, 0] } : { y: 0 }} transition={{ duration: 1.1 }}>
        <HomebotLogo className="text-[64px]" />
      </motion.span>
      <Check className="absolute -right-2 -bottom-2 ring-4 ring-[var(--canvas)]" />
    </div>
  );
}
