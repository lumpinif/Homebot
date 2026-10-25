import { useEffect, useRef, useState } from "react";
import { Check, Globe, Monitor, Moon, Sun } from "lucide-react";
import { AnimatePresence, motion } from "motion/react";
import { Loader } from "@/components/motion/loader";
import { useFluidHover } from "@/components/fluid/use-fluid-hover";
import { FluidHoverHighlight } from "@/components/fluid/fluid-hover-highlight";
import { spring } from "@/components/fluid/springs";
import { cn } from "@/lib/utils";
import type { SetupState, TokenView } from "@/api";
import { useSetup } from "@/app/setup";
import { Picker, Segmented } from "@/app/fluid";
import { GrokBotAvatar, HomebotMark, SiriOrb } from "@/app/brand";
import { AccountStep } from "@/app/steps/account";
import { LanguageStep } from "@/app/steps/language";
import { BotStep } from "@/app/steps/bot";
import { MakeStep, type Draft } from "@/app/steps/make";
import { PhoneStep } from "@/app/steps/phone";
import { ShortcutsView } from "@/app/shortcuts";
import { readTheme, setTheme, type ThemePref } from "@/theme";

type StepId = "account" | "language" | "bot" | "shortcut" | "phone";
const STEPS: StepId[] = ["account", "language", "bot", "shortcut", "phone"];

/** Per-viewer convenience only: whether the language step was looked at. */
const LANG_SEEN = "homebot.languageSeen";
const readSeen = (): boolean => {
  try {
    return localStorage.getItem(LANG_SEEN) === "1";
  } catch {
    return false;
  }
};
const writeSeen = (): void => {
  try {
    localStorage.setItem(LANG_SEEN, "1");
  } catch {
    // Private windows may refuse storage; the step just shows as not done.
  }
};

type Progress = Record<StepId, { done: boolean; open: boolean }>;

function progress(s: SetupState, langSeen: boolean): Progress {
  const account = s.credential !== null && s.credential.access !== "rejected";
  const bot = s.bots.length > 0;
  const shortcut = s.tokens.some((t) => t.state !== "retired" && t.kind === "ask");
  return {
    account: { done: account, open: true },
    language: { done: langSeen || bot, open: true },
    bot: { done: bot, open: account },
    shortcut: { done: shortcut, open: bot },
    phone: { done: s.tokens.some((t) => t.state === "active" && t.kind === "ask"), open: bot },
  };
}

/** The step list: the hover glides to the row nearest the pointer, the selected card slides between steps. */
function StepRail({ step, p, labels, go, label }: { step: StepId; p: Progress; labels: Record<StepId, string>; go: (s: StepId) => void; label: string }) {
  const ref = useRef<HTMLOListElement>(null);
  const hover = useFluidHover(ref, { axis: "y", isItemDisabled: (el) => el.hasAttribute("disabled") });
  return (
    <nav aria-label={label} className="hidden md:block">
      <ol ref={ref} {...hover.handlers} className="relative flex flex-col gap-1">
        <FluidHoverHighlight hover={hover} className="rounded-xl" />
        {STEPS.map((id, i) => {
          const current = id === step;
          return (
            <li key={id}>
              <button
                ref={(el) => hover.registerItem(i, el)}
                type="button"
                disabled={!p[id].open}
                aria-current={current ? "step" : undefined}
                onClick={() => go(id)}
                className={cn(
                  "relative flex h-11 w-full items-center gap-3 rounded-xl px-2.5 text-left text-[15px] outline-none transition-colors duration-150 focus-visible:ring-2 focus-visible:ring-ring disabled:opacity-40",
                  current ? "text-foreground" : "text-muted-foreground hover:text-foreground",
                )}
              >
                {current ? <motion.span layoutId="rail" transition={spring.moderate} className="absolute inset-0 z-0 rounded-xl bg-card shadow-sm ring-1 ring-border" /> : null}
                <span
                  className={cn(
                    "relative z-[1] grid size-6 shrink-0 place-items-center rounded-full text-[12px] font-semibold tabular-nums transition-colors duration-200",
                    p[id].done ? "bg-success text-white" : current ? "bg-primary text-primary-foreground" : "bg-muted text-muted-foreground",
                  )}
                >
                  <AnimatePresence mode="wait" initial={false}>
                    {p[id].done ? (
                      <motion.span key="done" initial={{ scale: 0 }} animate={{ scale: 1 }} transition={{ type: "spring", bounce: 0.5, duration: 0.4 }}>
                        <Check className="size-3.5" strokeWidth={3} />
                      </motion.span>
                    ) : (
                      <motion.span key="n">{i + 1}</motion.span>
                    )}
                  </AnimatePresence>
                </span>
                <span className="relative z-[1]">{labels[id]}</span>
              </button>
            </li>
          );
        })}
      </ol>
    </nav>
  );
}

const THEME_ICON: Record<ThemePref, React.ReactNode> = {
  system: <Monitor className="size-4" />,
  light: <Sun className="size-4" />,
  dark: <Moon className="size-4" />,
};

export default function App() {
  const { state, T, lang, saveSettings } = useSetup();
  const [view, setView] = useState<"setup" | "shortcuts">("setup");
  const [step, setStep] = useState<StepId>("account");
  const [dir, setDir] = useState(1);
  const [langSeen, setLangSeen] = useState(readSeen);
  const [draft, setDraft] = useState<Draft | null>(null);
  const [theme, setThemePref] = useState<ThemePref>(readTheme);
  const placed = useRef(false);
  const moved = useRef(false);
  const stepRef = useRef(step);
  stepRef.current = step;

  // First load: open where the user left off; a finished setup opens on the Shortcuts list.
  useEffect(() => {
    if (!state || placed.current) return;
    placed.current = true;
    const p = progress(state, langSeen);
    if (p.phone.done) setView("shortcuts");
    setStep(STEPS.find((id) => !p[id].done && p[id].open) ?? "shortcut");
  }, [state, langSeen]);

  // After a move, focus lands on the new step's title instead of the top of the document.
  useEffect(() => {
    if (!moved.current) return;
    const t = window.setTimeout(() => document.querySelector<HTMLElement>("[data-step-title]")?.focus({ preventScroll: true }), 400);
    return () => window.clearTimeout(t);
  }, [step, view]);

  const go = (next: StepId) => {
    moved.current = true;
    const from = stepRef.current;
    setDir(STEPS.indexOf(next) >= STEPS.indexOf(from) ? 1 : -1);
    if (from === "language" || next === "bot") {
      writeSeen();
      setLangSeen(true);
    }
    // A replacement request applies once, to the visit that asked for it.
    if (next !== "shortcut" || from === "shortcut") setDraft(null);
    setStep(next);
    setView("setup");
    // A long step may have scrolled the page; the next one starts at the top.
    if (window.scrollY > 0) window.scrollTo({ top: 0, behavior: "smooth" });
  };
  /** A step's own "done" moves on only while the user is still on that step. */
  const advance = (from: StepId, next: StepId) => () => {
    if (stepRef.current === from) go(next);
  };

  if (!state) {
    return (
      <div className="grid min-h-svh place-items-center">
        <Loader size={28} />
      </div>
    );
  }
  const p = progress(state, langSeen);
  const liveCount = state.tokens.filter((t) => t.state !== "retired").length;
  const labels: Record<StepId, string> = { account: T.stepAccount, language: T.stepLanguage, bot: T.stepBot, shortcut: T.stepShortcut, phone: T.stepPhone };

  const replace = (t: TokenView) => {
    go("shortcut");
    setDraft({ bot: t.bot, replaces: t.id, seq: Date.now() });
  };

  return (
    <div className="min-h-svh bg-background text-foreground">
      <header className="sticky top-0 z-40 border-b border-border/60 bg-background/75 backdrop-blur-xl backdrop-saturate-150">
        <div className="mx-auto flex h-14 max-w-5xl items-center gap-2 px-4 sm:gap-3 sm:px-6">
          <div className="flex flex-1 items-center gap-2.5">
            <HomebotMark />
            <span className="hidden text-[17px] font-semibold tracking-tight sm:inline">{T.title}</span>
          </div>
          <Segmented
            label={T.title}
            value={view}
            onChange={(v) => {
              moved.current = true;
              setView(v);
            }}
            options={[
              { value: "setup", label: T.tabSetup },
              {
                value: "shortcuts",
                name: T.tabShortcuts,
                label: liveCount ? (
                  <>
                    {T.tabShortcuts}
                    <span className="tabular-nums opacity-60">{liveCount}</span>
                  </>
                ) : (
                  T.tabShortcuts
                ),
              },
            ]}
          />
          <div className="flex flex-1 items-center justify-end gap-0.5">
            <Picker
              label={T.pageLanguage}
              align="end"
              value={lang}
              onChange={(v) => void saveSettings({ uiLang: v })}
              options={state.options.uiLangs.map((l) => ({ value: l.code, label: l.label }))}
              trigger={
                <>
                  <Globe className="size-4" />
                  <span className="hidden sm:inline">{state.options.uiLangs.find((l) => l.code === lang)?.label}</span>
                </>
              }
            />
            <Picker
              label={T.theme}
              align="end"
              value={theme}
              onChange={(v) => {
                setTheme(v);
                setThemePref(v);
              }}
              options={(["system", "light", "dark"] as const).map((v) => ({
                value: v,
                label: { system: T.themeSystem, light: T.themeLight, dark: T.themeDark }[v],
                icon: <span className="text-muted-foreground">{THEME_ICON[v]}</span>,
              }))}
              trigger={THEME_ICON[theme]}
            />
          </div>
        </div>
      </header>

      {/* The top gap centres a ~520px block in the window, a little above the middle, and stays
          put while steps of different heights come and go. */}
      <main className="mx-auto max-w-5xl overflow-x-clip px-4 pt-6 pb-24 md:pt-[max(2rem,calc((100svh-3.5rem-520px)*0.4))] sm:px-6">
        <AnimatePresence mode="wait" initial={false}>
          {view === "setup" ? (
            <motion.div
              key="setup"
              initial={{ opacity: 0, y: 8 }}
              animate={{ opacity: 1, y: 0 }}
              exit={{ opacity: 0, y: -8, transition: spring.moderate.exit }}
              transition={spring.slow}
              className="grid gap-8 md:grid-cols-[264px_minmax(0,1fr)] md:gap-14"
            >
              <aside className="flex flex-col gap-5 md:sticky md:top-28 md:self-start md:gap-8">
                <div className="flex flex-col gap-3">
                  <motion.h1
                    key={lang}
                    initial={{ opacity: 0, filter: "blur(6px)", y: 4 }}
                    animate={{ opacity: 1, filter: "blur(0px)", y: 0 }}
                    transition={{ duration: 0.5, ease: [0.22, 1, 0.36, 1] }}
                    className="text-[24px] leading-[1.25] font-semibold tracking-tight text-balance [text-box:trim-both_cap_alphabetic] md:text-[27px]"
                  >
                    {T.heroTitle.split(/(\{bot\}|\{siri\})/).map((part, i) =>
                      part === "{bot}" ? (
                        <span key={i} className="whitespace-nowrap">
                          <GrokBotAvatar className="mr-[0.18em]" />
                          Grok Bot
                        </span>
                      ) : part === "{siri}" ? (
                        <span key={i} className="whitespace-nowrap">
                          <SiriOrb className="mr-[0.18em] size-[0.86em] align-[-0.078em]" />
                          Siri
                        </span>
                      ) : (
                        part
                      ),
                    )}
                  </motion.h1>
                  <p className="text-[14px] text-pretty text-muted-foreground md:text-[15px]">{T.heroSub}</p>
                </div>
                {/* Phones: a five-segment progress bar and the current step's name. */}
                <div className="flex flex-col gap-1 md:hidden">
                  <div className="flex gap-1.5">
                    {STEPS.map((id) => (
                      <button
                        key={id}
                        type="button"
                        aria-label={labels[id]}
                        disabled={!p[id].open}
                        onClick={() => go(id)}
                        className="group flex h-6 flex-1 items-center outline-none"
                      >
                        <span className="block h-1.5 w-full overflow-hidden rounded-full bg-border group-focus-visible:ring-2 group-focus-visible:ring-ring">
                          <motion.span
                            initial={false}
                            animate={{ scaleX: p[id].done || id === step ? 1 : 0 }}
                            transition={spring.slow}
                            className={cn("block h-full w-full origin-left", p[id].done ? "bg-success" : "bg-primary")}
                          />
                        </span>
                      </button>
                    ))}
                  </div>
                  <p className="text-[13px] text-muted-foreground tabular-nums">
                    {STEPS.indexOf(step) + 1}/{STEPS.length} · {labels[step]}
                  </p>
                </div>
                <StepRail step={step} p={p} labels={labels} go={go} label={T.tabSetup} />
              </aside>

              <section className="relative min-w-0 overflow-hidden rounded-[28px] border border-border/70 bg-card px-5 py-9 shadow-[0_1px_2px_rgba(0,0,0,0.04),0_12px_40px_-12px_rgba(0,0,0,0.12)] sm:px-10 sm:py-12">
                <AnimatePresence mode="wait" initial={false} custom={dir}>
                  <motion.div
                    key={step}
                    custom={dir}
                    variants={{
                      enter: (d: number) => ({ opacity: 0, x: 24 * d, filter: "blur(4px)" }),
                      center: { opacity: 1, x: 0, filter: "blur(0px)" },
                      exit: (d: number) => ({ opacity: 0, x: -24 * d, filter: "blur(4px)", transition: spring.moderate.exit }),
                    }}
                    initial="enter"
                    animate="center"
                    exit="exit"
                    transition={spring.slow}
                    className="mx-auto max-w-lg"
                  >
                    {step === "account" ? <AccountStep onDone={advance("account", "language")} /> : null}
                    {step === "language" ? <LanguageStep onDone={() => go(p.bot.open ? "bot" : "account")} /> : null}
                    {step === "bot" ? <BotStep onDone={advance("bot", "shortcut")} /> : null}
                    {step === "shortcut" ? <MakeStep draft={draft} onDraftUsed={() => setDraft(null)} onBuilt={advance("shortcut", "phone")} /> : null}
                    {step === "phone" ? <PhoneStep onMake={() => go("shortcut")} /> : null}
                  </motion.div>
                </AnimatePresence>
              </section>
            </motion.div>
          ) : (
            <motion.div
              key="shortcuts"
              initial={{ opacity: 0, y: 8 }}
              animate={{ opacity: 1, y: 0 }}
              exit={{ opacity: 0, y: -8, transition: spring.moderate.exit }}
              transition={spring.slow}
              className="mx-auto max-w-2xl"
            >
              <ShortcutsView onReplace={replace} onMake={() => go(p.shortcut.open ? "shortcut" : (STEPS.find((id) => !p[id].done) ?? "account"))} />
            </motion.div>
          )}
        </AnimatePresence>
      </main>
    </div>
  );
}
