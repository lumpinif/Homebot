// Page-wide state: the gateway's SetupState, the page language's strings, toasts and confirms.
import { createContext, useCallback, useContext, useEffect, useMemo, useRef, useState, type ReactNode } from "react";
import { AnimatedToastStack, useAnimatedToastStack } from "@/components/motion/animated-toast-stack";
import { CenterMorphModal, CenterMorphModalContent } from "@/components/motion/center-morph-modal";
import { Button } from "@/components/motion/button/base";
import { api, ApiFailure, type SetupState, type ShortcutBuild } from "@/api";
import { STRINGS, type Strings, type UiLang } from "@/i18n";

export interface Confirm {
  title: string;
  body: string;
  action: string;
}

interface SetupContextValue {
  state: SetupState | null;
  T: Strings;
  lang: UiLang;
  setState: (s: SetupState) => void;
  refresh: () => Promise<void>;
  /** Run an API action; report a failure as a toast and return null. */
  run: <R>(fn: () => Promise<R>, opts?: { done?: string }) => Promise<R | null>;
  toast: (title: string, status?: "success" | "error" | "info") => void;
  confirm: (c: Confirm) => Promise<boolean>;
  /** Change page, Siri or iPhone language; when changes overlap, the last one asked for wins. */
  saveSettings: (patch: { uiLang?: string; siriLang?: string; phoneLang?: string; appleSigning?: boolean }, opts?: { done?: string }) => Promise<void>;
  /** The Shortcut made in this visit, shown in the iPhone step. */
  build: ShortcutBuild | null;
  setBuild: (b: ShortcutBuild | null) => void;
}

const SetupContext = createContext<SetupContextValue | null>(null);

export function useSetup(): SetupContextValue {
  const ctx = useContext(SetupContext);
  if (!ctx) throw new Error("useSetup outside SetupProvider");
  return ctx;
}

const isUiLang = (l: string | undefined): l is UiLang => l !== undefined && Object.hasOwn(STRINGS, l);
const lookup = (table: Record<string, string>, code: string | undefined): string | undefined =>
  code !== undefined && Object.hasOwn(table, code) ? table[code] : undefined;

export function SetupProvider({ children }: { children: ReactNode }) {
  const [state, setRawState] = useState<SetupState | null>(null);
  const [build, setBuild] = useState<ShortcutBuild | null>(null);
  // Every change from an action bumps this; a background refresh that started earlier
  // then knows its answer is older and drops it.
  const version = useRef(0);
  const setState = useCallback((s: SetupState) => {
    version.current += 1;
    setRawState(s);
  }, []);
  const [pending, setPending] = useState<Confirm | null>(null);
  const answer = useRef<((ok: boolean) => void) | null>(null);
  const { toasts, showToast, dismissToast } = useAnimatedToastStack({ defaultDuration: 3200, limit: 3 });

  const lang: UiLang = isUiLang(state?.settings.uiLang) ? state.settings.uiLang : "en";
  const T = STRINGS[lang];

  useEffect(() => {
    document.documentElement.lang = lang;
    document.title = T.title;
  }, [lang, T]);

  const toast = useCallback(
    (title: string, status: "success" | "error" | "info" = "success") => {
      showToast({ title, status, duration: status === "error" ? 6000 : 2400 });
    },
    [showToast],
  );

  const run = useCallback(
    async <R,>(fn: () => Promise<R>, opts?: { done?: string }): Promise<R | null> => {
      try {
        const r = await fn();
        if (opts?.done) toast(opts.done);
        return r;
      } catch (e) {
        const known = e instanceof ApiFailure ? lookup(T.errors, e.code) : undefined;
        toast(known ?? (e instanceof Error ? e.message : T.failed), "error");
        return null;
      }
    },
    [T, toast],
  );

  // Each refresh takes a version of its own: a newer refresh or any change made since it
  // started wins over its answer.
  const refresh = useCallback(async () => {
    const mine = ++version.current;
    const s = await run(() => api<SetupState>("/api/state"));
    if (s && version.current === mine) setRawState(s);
  }, [run]);
  const settingsSeq = useRef(0);
  const saveSettings = useCallback(
    async (patch: { uiLang?: string; siriLang?: string; phoneLang?: string; appleSigning?: boolean }, opts?: { done?: string }) => {
      const mine = ++settingsSeq.current;
      const s = await run(() => api<SetupState>("/api/settings", patch), opts);
      if (s && mine === settingsSeq.current) setState(s);
    },
    [run, setState],
  );
  // The listeners below live for the whole page; they call the latest refresh, in the
  // current page language.
  const refreshRef = useRef(refresh);
  refreshRef.current = refresh;

  // A Shortcut revoked, or its bot removed, has nothing left to deliver.
  useEffect(() => {
    if (build && state && !state.tokens.some((t) => t.id === build.tokenId && t.state !== "retired")) setBuild(null);
  }, [build, state]);

  // The phone's first use changes token state on the server; pick that up on return.
  useEffect(() => {
    void refreshRef.current();
    const onVisible = () => {
      if (document.visibilityState === "visible") void refreshRef.current();
    };
    window.addEventListener("focus", onVisible);
    document.addEventListener("visibilitychange", onVisible);
    return () => {
      window.removeEventListener("focus", onVisible);
      document.removeEventListener("visibilitychange", onVisible);
    };
  }, []);

  const confirm = useCallback((c: Confirm) => {
    answer.current?.(false);
    setPending(c);
    return new Promise<boolean>((resolve) => {
      answer.current = resolve;
    });
  }, []);
  const settle = (ok: boolean) => {
    answer.current?.(ok);
    answer.current = null;
    setPending(null);
  };
  // Keep the last text while the modal folds away.
  const shown = useRef<Confirm | null>(null);
  if (pending) shown.current = pending;

  const value = useMemo<SetupContextValue>(
    () => ({ state, T, lang, setState, refresh, run, toast, confirm, saveSettings, build, setBuild }),
    [state, T, lang, setState, refresh, run, toast, confirm, saveSettings, build],
  );

  return (
    <SetupContext.Provider value={value}>
      {children}
      <AnimatedToastStack toasts={toasts} onDismiss={dismissToast} position="bottom-center" fixed maxVisible={3} />
      <CenterMorphModal open={pending !== null} onOpenChange={(open) => !open && settle(false)}>
        <CenterMorphModalContent ariaLabel={shown.current?.title ?? ""} ariaDescribedBy="confirm-body" showCloseButton={false} className="max-w-[22rem]">
          <div className="flex flex-col gap-2 px-6 pt-7 pb-5 text-center">
            <p className="text-[17px] font-semibold tracking-tight">{shown.current?.title}</p>
            <p id="confirm-body" className="text-sm text-muted-foreground">
              {shown.current?.body}
            </p>
          </div>
          <div className="grid grid-cols-2 gap-2 px-5 pb-5">
            <Button variant="secondary" onClick={() => settle(false)}>
              {T.cancel}
            </Button>
            <Button className="bg-destructive text-white hover:bg-destructive/90" onClick={() => settle(true)}>
              {shown.current?.action}
            </Button>
          </div>
        </CenterMorphModalContent>
      </CenterMorphModal>
    </SetupContext.Provider>
  );
}

/**
 * A Siri language's name, as in the menus (each language named in itself). Shortcuts made for an
 * older English variant (en-GB...) show as English.
 */
export function useLangName(): (code: string) => string {
  const { state } = useSetup();
  const find = (c: string) => state?.options.siriLangs.find((l) => l.code === c)?.label;
  return (code) => find(code) ?? (code.startsWith("en-") ? find("en-US") : undefined) ?? code;
}

export { lookup };
