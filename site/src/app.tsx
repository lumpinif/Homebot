// The site's shell: one header row (the name, the three views as segmented tabs, language and
// appearance) over the view on the canvas. On a Mac-sized window everything under the header
// scrolls, with its scrollbar at the window's edge and content fading under the header. On a
// phone the tabs take a second row, which stays on screen, and the page scrolls natively.
import { AnimatePresence, motion } from "motion/react";
import { useReducedMotion } from "@/lib/reduced-motion";
import { useEffect, useId, useMemo, useRef, useState, useSyncExternalStore, type ReactNode } from "react";
import { ChevronDown, Globe, Monitor, Moon, Sun } from "lucide-react";
import { cn } from "@/lib/utils";
import { detectLang, LANG_OPTIONS, LangContext, STRINGS, UI_LANGS, useT, type Strings, type UiLang } from "@/i18n";
import { GoContext, PAGES, REPO_URL, type Page } from "@/state";
import { HomebotLogo } from "@/ui/brand";
import { DropdownContent, DropdownMenu, DropdownTrigger } from "@/ui/ff/dropdown";
import { MenuItem } from "@/ui/ff/menu-item";
import { seg, Segmented, spring } from "@/ui/kit";
import { ScrollArea } from "@/ui/scroll-area";
import { HomeView } from "@/views/home";
import { InstallView } from "@/views/install";
import { PrivacyView } from "@/views/privacy";

type Theme = "system" | "light" | "dark";

const WIDE = "(min-width: 768px)";
const useWide = () =>
  useSyncExternalStore(
    (cb) => {
      const mq = matchMedia(WIDE);
      mq.addEventListener("change", cb);
      return () => mq.removeEventListener("change", cb);
    },
    () => matchMedia(WIDE).matches,
  );

const readPage = (): Page => {
  const h = location.hash.replace(/^#\/?/, "");
  return (PAGES as readonly string[]).includes(h) ? (h as Page) : "home";
};

function store<T extends string>(key: string, fallback: T, valid: readonly T[]): [T, (v: T) => void] {
  let v = fallback;
  try {
    const s = localStorage.getItem(key);
    if (s && (valid as readonly string[]).includes(s)) v = s as T;
  } catch {
    /* storage blocked: defaults */
  }
  return [v, (n: T) => {
    try {
      localStorage.setItem(key, n);
    } catch {
      /* ignore */
    }
  }];
}

export function App() {
  const [initialTheme, saveTheme] = useMemo(() => store<Theme>("hb-theme", "system", ["system", "light", "dark"]), []);
  const [initialLang, saveLang] = useMemo(() => store<UiLang>("hb-lang", detectLang(), UI_LANGS), []);
  const [theme, setTheme] = useState<Theme>(initialTheme);
  const [lang, setLang] = useState<UiLang>(initialLang);
  const [page, setPage] = useState<Page>(readPage);
  const wide = useWide();
  const viewport = useRef<HTMLDivElement>(null);
  const toTop = () => {
    viewport.current?.scrollTo({ top: 0 });
    scrollTo({ top: 0 });
  };

  // Theme: html.dark from the menu, or from the system when the menu says System.
  useEffect(() => {
    const mq = matchMedia("(prefers-color-scheme: dark)");
    const apply = () => document.documentElement.classList.toggle("dark", theme === "dark" || (theme === "system" && mq.matches));
    apply();
    mq.addEventListener("change", apply);
    return () => mq.removeEventListener("change", apply);
  }, [theme]);

  useEffect(() => {
    document.documentElement.lang = lang;
  }, [lang]);

  // Outside the scroll area, scroll keys go to the document, which doesn't scroll here: pass them
  // on, as a window that scrolls would take them. Page keys pass from anywhere but a text field;
  // Space and the arrows only with nothing focused, since controls use them.
  useEffect(() => {
    if (!wide) return;
    const key = (e: KeyboardEvent) => {
      const el = viewport.current;
      if (!el || e.defaultPrevented || e.altKey || e.ctrlKey || e.metaKey) return;
      const at = document.activeElement;
      const idle = !at || at === document.body;
      if (!idle && (el.contains(at) || at.matches("input, textarea, select, [contenteditable]"))) return;
      if (!idle && !["PageDown", "PageUp", "Home", "End"].includes(e.key)) return;
      const page = el.clientHeight - 40;
      const by: Record<string, number> = { ArrowDown: 40, ArrowUp: -40, PageDown: page, PageUp: -page, " ": e.shiftKey ? -page : page };
      if (e.key === "Home" || e.key === "End") el.scrollTo({ top: e.key === "Home" ? 0 : el.scrollHeight });
      else if (e.key in by) el.scrollBy({ top: by[e.key] });
      else return;
      e.preventDefault();
    };
    addEventListener("keydown", key);
    return () => removeEventListener("keydown", key);
  }, [wide]);

  useEffect(() => {
    const on = () => {
      setPage(readPage());
      toTop();
    };
    addEventListener("hashchange", on);
    addEventListener("popstate", on);
    return () => {
      removeEventListener("hashchange", on);
      removeEventListener("popstate", on);
    };
  }, []);

  const t = STRINGS[lang];
  useEffect(() => {
    document.title = page === "home" ? "Homebot — Siri for your Grok Bot" : `${titleOf(page, t)} · Homebot`;
  }, [page, t]);

  const go = (p: Page) => {
    if (p === page) return;
    history.pushState(null, "", p === "home" ? location.pathname : `#${p}`);
    setPage(p);
    toTop();
    document.getElementById("main")?.focus({ preventScroll: true });
  };

  const prefs: Prefs = {
    theme,
    setTheme: (v) => {
      setTheme(v);
      saveTheme(v);
    },
    lang,
    setLang: (v) => {
      setLang(v);
      saveLang(v);
    },
  };
  // The footer sits at the bottom of the window on a short page, after the content on a long one.
  const content = (
    <div className={cn("flex flex-col", wide ? "min-h-[calc(100dvh-56px)]" : "flex-1")}>
      <main id="main" tabIndex={-1} className="flex-1 outline-none">
        <View page={page} />
      </main>
      <Footer />
    </div>
  );

  return (
    <LangContext.Provider value={{ lang, t }}>
      <GoContext.Provider value={go}>
        <a
          href="#main"
          onClick={(e) => {
            // Not a hash change: "#main" isn't a view.
            e.preventDefault();
            document.getElementById("main")?.focus();
          }}
          className="sr-only focus:not-sr-only focus:fixed focus:top-3 focus:left-3 focus:z-50 focus:rounded-lg focus:bg-canvas focus:px-3 focus:py-2"
        >
          {t.skip}
        </a>
        {wide ? (
          <div className="flex h-dvh flex-col">
            <header className="grid h-[56px] shrink-0 grid-cols-[1fr_auto_1fr] items-center gap-4 px-6">
              <Brand go={go} />
              <NavTabs page={page} go={go} />
              <Controls {...prefs} className="justify-self-end" />
            </header>
            {/* Radix wraps the content in a display:table box; a block box lets text wrap normally. */}
            <ScrollArea className="min-h-0 flex-1" viewportRef={viewport} viewportClassName="scroll-fade [&>div]:!block">
              {content}
            </ScrollArea>
          </div>
        ) : (
          <div className="flex min-h-dvh flex-col">
            <header className="flex h-[52px] items-center justify-between gap-3 px-4">
              <Brand go={go} />
              <Controls {...prefs} compact />
            </header>
            <div className="sticky top-0 z-30 bg-canvas/85 px-4 pb-2 backdrop-blur-xl">
              <NavTabs page={page} go={go} className="flex w-full" />
            </div>
            {content}
          </div>
        )}
      </GoContext.Provider>
    </LangContext.Provider>
  );
}

function titleOf(p: Page, t: Strings) {
  return { home: t.navHome, install: t.navInstall, privacy: t.navPrivacy }[p];
}

function View({ page }: { page: Page }) {
  const reduce = useReducedMotion();
  const views: Record<Page, ReactNode> = { home: <HomeView />, install: <InstallView />, privacy: <PrivacyView /> };
  return (
    <AnimatePresence mode="wait" initial={false}>
      <motion.div
        key={page}
        initial={reduce ? { opacity: 0 } : { opacity: 0, y: 8 }}
        animate={{ opacity: 1, y: 0 }}
        exit={{ opacity: 0 }}
        transition={{ duration: reduce ? 0.1 : 0.22, ease: [0.25, 0.1, 0.25, 1] }}
        className="mx-auto w-full max-w-[760px] px-5 pb-28 sm:px-10"
      >
        {views[page]}
      </motion.div>
    </AnimatePresence>
  );
}

function Brand({ go }: { go: (p: Page) => void }) {
  return (
    <a
      href="./"
      onClick={(e) => {
        e.preventDefault();
        go("home");
      }}
      className="flex items-center gap-2 justify-self-start"
    >
      <HomebotLogo className="text-[26px]" />
      <span className="text-[17px] font-semibold tracking-[-0.01em]">Homebot</span>
    </a>
  );
}

/** The three views as segmented tabs: the appearance switch's look, with links' semantics. */
function NavTabs({ page, go, className }: { page: Page; go: (p: Page) => void; className?: string }) {
  const { t } = useT();
  const reduce = useReducedMotion();
  const id = useId();
  return (
    <nav aria-label={t.sections} className={cn(seg.track, className)}>
      {PAGES.map((p) => {
        const on = p === page;
        return (
          <a
            key={p}
            href={p === "home" ? "./" : `#${p}`}
            aria-current={on ? "page" : undefined}
            onClick={(e) => {
              e.preventDefault();
              go(p);
            }}
            className={cn(seg.item, "text-center", on ? seg.on : seg.off)}
          >
            {on && <motion.span layoutId={`nav-${id}`} transition={reduce ? { duration: 0 } : spring} className={seg.thumb} />}
            <span className="relative">{titleOf(p, t)}</span>
          </a>
        );
      })}
    </nav>
  );
}

type Prefs = { theme: Theme; setTheme: (t: Theme) => void; lang: UiLang; setLang: (l: UiLang) => void };

/** Page language and appearance, at the header's end. `compact`: the language button shows only
 *  the globe, for a phone's width. */
function Controls({ theme, setTheme, lang, setLang, className, compact }: Prefs & { className?: string; compact?: boolean }) {
  const { t } = useT();
  return (
    <div className={cn("flex items-center gap-2", className)}>
      <LanguageMenu lang={lang} setLang={setLang} compact={compact} />
      <Segmented
        label={t.appearance}
        value={theme}
        onChange={setTheme}
        options={[
          { value: "system", name: t.themeSystem, label: <Monitor className="size-[14px]" strokeWidth={1.9} /> },
          { value: "light", name: t.themeLight, label: <Sun className="size-[14px]" strokeWidth={1.9} /> },
          { value: "dark", name: t.themeDark, label: <Moon className="size-[14px]" strokeWidth={1.9} /> },
        ]}
      />
    </div>
  );
}

/** The eleven languages, each in its own name, in Fluid Functionalism's dropdown (src/ui/ff/). */
function LanguageMenu({ lang, setLang, compact }: { lang: UiLang; setLang: (l: UiLang) => void; compact?: boolean }) {
  const { t } = useT();
  const at = LANG_OPTIONS.findIndex((l) => l.code === lang);
  const name = LANG_OPTIONS[at]?.name;
  return (
    <DropdownMenu>
      <DropdownTrigger
        aria-label={compact ? `${t.language}: ${name}` : t.language}
        className="flex h-[30px] items-center gap-1.5 rounded-[10px] bg-fill-2 pr-2 pl-2.5 text-[13px] text-label transition-colors outline-none hover:bg-[color-mix(in_srgb,var(--fill-2),var(--label)_6%)] focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-accent data-[popup-open]:bg-[color-mix(in_srgb,var(--fill-2),var(--label)_6%)]"
      >
        <Globe className="size-[14px] text-label-2" strokeWidth={1.9} aria-hidden />
        {!compact && (
          <span lang={lang} className="whitespace-nowrap">
            {name}
          </span>
        )}
        <ChevronDown className="size-[13px] text-label-2" strokeWidth={2.2} aria-hidden />
      </DropdownTrigger>
      <DropdownContent checkedIndex={at} align="end" sideOffset={6} className="w-56">
        {LANG_OPTIONS.map((l, i) => (
          <MenuItem key={l.code} index={i} label={l.name} checked={i === at} onSelect={() => setLang(l.code)} />
        ))}
      </DropdownContent>
    </DropdownMenu>
  );
}

function Footer() {
  const { t } = useT();
  return (
    <footer className="mx-auto w-full max-w-[760px] px-5 pb-6 sm:px-10">
      <div className="flex flex-col gap-2 border-t border-separator pt-4 text-[12px] leading-relaxed text-label-3 sm:flex-row sm:items-start sm:justify-between sm:gap-8">
        <p className="max-w-[460px]">{t.footer}</p>
        <p className="shrink-0">
          <a href={REPO_URL} className="transition-colors hover:text-label-2">
            {t.source}
          </a>
          <span aria-hidden> · </span>
          <span>MIT</span>
          <span aria-hidden> · </span>
          <a href="THIRD_PARTY.md" className="transition-colors hover:text-label-2">
            {t.notices}
          </a>
        </p>
      </div>
    </footer>
  );
}
