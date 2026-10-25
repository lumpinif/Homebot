import { useEffect, useRef, useState } from "react";
import { Mic, Sparkles } from "lucide-react";
import { AnimatePresence, motion } from "motion/react";
import { Input } from "@/components/motion/input";
import { Switch } from "@/components/motion/switch";
import { StatefulButton, type ButtonState } from "@/components/motion/button/stateful";
import { Alert, AlertContent, AlertDescription, AlertIcon } from "@/components/motion/alert";
import { Collapsible, CollapsibleContent, CollapsibleIndicator, CollapsibleTrigger } from "@/components/motion/collapsible";
import { api, ApiFailure, type ShortcutBuild, type ShortcutPreview, type TokenView } from "@/api";
import { lookup, useSetup } from "../setup";
import { Group, Label, Note, Row, StepHeader } from "../pieces";
import { Chips, Picker } from "../fluid";
import { SiriOrb } from "../brand";

/** What the Shortcuts list asks for when it starts a replacement. */
export interface Draft {
  bot: string;
  replaces: string;
  seq: number;
}

/** The words said to Siri are in Siri's language, whatever the page language is (Apple writes 嘿Siri without a space). */

const stateLabel = (T: ReturnType<typeof useSetup>["T"], s: TokenView["state"]) => ({ pending: T.statePending, active: T.stateActive, retired: T.stateRetired })[s];

export function MakeStep({ draft, onDraftUsed, onBuilt }: { draft: Draft | null; onDraftUsed: () => void; onBuilt: () => void }) {
  const { state, T, setState, run, setBuild, saveSettings } = useSetup();
  const bots = state?.bots ?? [];
  const [bot, setBot] = useState(bots[0]?.key ?? "");
  const [name, setName] = useState("");
  const [url, setUrl] = useState("");
  const [replaces, setReplaces] = useState<string | null>(null);
  const [probe, setProbe] = useState(false);
  // Each preview remembers the inputs it answers, so Build never acts on an older one.
  const [preview, setPreview] = useState<{ key: string; value: ShortcutPreview } | null>(null);
  const [previewError, setPreviewError] = useState<string | null>(null);
  const [btn, setBtn] = useState<ButtonState>("idle");
  const seq = useRef(0);
  const alive = useRef(true);
  const timer = useRef(0);
  useEffect(() => {
    alive.current = true;
    return () => {
      alive.current = false;
      window.clearTimeout(timer.current);
    };
  }, []);

  // A replacement started from the Shortcuts list.
  useEffect(() => {
    if (!draft) return;
    setBot(draft.bot);
    setName("");
    setProbe(false);
    setReplaces(draft.replaces);
    // Applied once: coming back to this step later keeps what the user chose since.
    onDraftUsed();
    // onDraftUsed only clears the request in the parent.
  }, [draft]);

  // Keep the chosen bot valid as bots come and go.
  useEffect(() => {
    if (!bots.some((b) => b.key === bot)) setBot(bots[0]?.key ?? "");
  }, [bots, bot]);

  // The switch is the user's consent to Apple's signing service; the server remembers it.
  // A flip counts at once: Make sends what the switch shows, even before the save returns.
  const [flipped, setFlipped] = useState<boolean | null>(null);
  const signing = flipped ?? state?.signing.consent ?? false;
  const setSigning = async (on: boolean) => {
    setFlipped(on);
    await saveSettings({ appleSigning: on });
    setFlipped((f) => (f === on ? null : f));
  };
  const probeOn = (state?.probe.enabled ?? false) && probe;
  // Wait tests never replace a voice Shortcut, and are never replaced by one.
  const usable = (state?.tokens ?? []).filter((t) => t.bot === bot && t.state !== "retired" && t.kind === "ask").reverse();
  const replacing = probeOn ? "" : (replaces ?? usable.find((t) => t.state === "active")?.id ?? "");
  const validReplacing = usable.some((t) => t.id === replacing) ? replacing : "";

  const body = () => ({
    bot,
    name: name.trim() || undefined,
    url: url.trim() || undefined,
    probe: probeOn,
    // Preview and build both see the token being replaced, so they pick the same phrase
    // (milestone review S2).
    replaces: validReplacing || undefined,
  });

  // Live preview, lightly debounced while typing.
  // Token states and labels are in the key too: a revoke elsewhere can free a phrase.
  const key = JSON.stringify([body(), state?.settings.siriLang, state?.settings.phoneLang, (state?.tokens ?? []).map((t) => [t.id, t.state, t.label])]);
  useEffect(() => {
    const mine = ++seq.current;
    if (!bot) return;
    const t = window.setTimeout(async () => {
      try {
        const p = await api<ShortcutPreview>("/api/shortcuts/preview", body());
        if (mine !== seq.current) return;
        setPreview({ key, value: p });
        setPreviewError(null);
      } catch (e) {
        if (mine !== seq.current) return;
        setPreview(null);
        setPreviewError((e instanceof ApiFailure && lookup(T.errors, e.code)) || (e instanceof Error ? e.message : T.failed));
      }
      // The first preview goes out at once; later ones wait for a pause in typing.
    }, preview ? 180 : 0);
    return () => window.clearTimeout(t);
    // body() is derived from the same values as `key`.
  }, [key, T]);

  const shown = preview?.value ?? null;
  const current = preview !== null && preview.key === key;
  const blocking = shown?.problems.some((p) => p.blocking) ?? false;

  const make = async () => {
    setBtn("loading");
    const r = await run(() => api<ShortcutBuild>("/api/shortcuts", { ...body(), sign: signing }));
    if (!alive.current) {
      // The user moved on; keep the result, but do not pull them back.
      if (r) {
        setState(r.state);
        setBuild(r);
      }
      return;
    }
    if (!r) return setBtn("error");
    setState(r.state);
    setBuild(r);
    setBtn("success");
    setName("");
    setReplaces(null);
    timer.current = window.setTimeout(() => {
      setBtn("idle");
      onBuilt();
    }, 650);
  };

  if (!state) return null;
  const phrase = shown?.name ?? "…";

  return (
    <div className="flex flex-col gap-8">
      <StepHeader icon={Sparkles} tint="bg-gradient-to-b from-pink-400 to-fuchsia-600" title={T.shortcutTitle} />

      {/* The conversation the Shortcut makes possible, as the preview. */}
      <div className="relative overflow-hidden rounded-3xl bg-gradient-to-b from-zinc-900 to-black p-6 text-white shadow-xl ring-1 ring-white/10 sm:p-8">
        <div aria-hidden className="siri-glow pointer-events-none absolute -bottom-24 left-1/2 h-48 w-[120%] -translate-x-1/2 rounded-full opacity-70 blur-3xl" />
        {/* Sized for both bubbles, so the card does not grow when the first preview lands. */}
        <div className="relative flex min-h-[7.5rem] flex-col justify-end gap-4" aria-live="polite" aria-atomic="true">
          <div className="flex items-end justify-end gap-2">
            <AnimatePresence mode="wait">
              {shown ? (
                <motion.p
                  key={phrase}
                  initial={{ opacity: 0, y: 6, filter: "blur(6px)" }}
                  animate={{ opacity: 1, y: 0, filter: "blur(0px)" }}
                  exit={{ opacity: 0, y: -6, filter: "blur(6px)" }}
                  transition={{ duration: 0.25 }}
                  className="max-w-[85%] rounded-[1.4rem] rounded-br-md bg-[#0a84ff] px-4 py-2.5 text-[19px] leading-snug font-medium sm:text-[22px]"
                >
                  {shown.say}
                </motion.p>
              ) : null}
            </AnimatePresence>
          </div>
          <div className="flex items-end gap-2">
            <SiriOrb />
            <AnimatePresence mode="wait">
              {shown ? (
                <motion.p
                  key={shown.prompt ?? shown.kind}
                  initial={{ opacity: 0, y: 6 }}
                  animate={{ opacity: 1, y: 0 }}
                  exit={{ opacity: 0, y: -6 }}
                  transition={{ duration: 0.25, delay: 0.08 }}
                  className="max-w-[85%] rounded-[1.4rem] rounded-bl-md bg-white/12 px-4 py-2.5 text-[17px] leading-snug text-white/90"
                >
                  {shown.kind === "probe" ? T.probeSays : shown.prompt}
                </motion.p>
              ) : null}
            </AnimatePresence>
          </div>
        </div>
      </div>

      <div className="flex flex-col gap-3">
        {bots.length > 1 ? (
          <div className="flex flex-col gap-1.5">
            <Label id="make-bot-label">{T.bot}</Label>
            <Picker
              label={T.bot}
              labelId="make-bot-label"
              value={bot}
              onChange={(v) => {
                setBot(v);
                setName("");
                setReplaces(null);
              }}
              options={bots.map((b) => ({ value: b.key, label: b.name }))}
            />
          </div>
        ) : null}

        {!probeOn ? (
          <Input
            label={T.phrase}
            maxLength={60}
            autoComplete="off"
            spellCheck={false}
            placeholder={shown?.name ?? ""}
            value={name}
            onChange={setName}
            leftIcon={<Mic />}
            error={blocking}
            classNames={{ label: "text-[13px] text-muted-foreground" }}
          />
        ) : null}

        {shown && !probeOn && shown.alternatives.length ? (
          <Chips label={T.alternatives} items={shown.alternatives} onPick={setName} />
        ) : null}

        {(shown?.problems ?? []).map((p) => (
          <Alert key={p.code} variant={p.blocking ? "destructive" : "warning"} className="rounded-2xl">
            <AlertIcon />
            <AlertContent>
              <AlertDescription>{lookup(T.problems, p.blocking ? p.code : `${p.code}-advice`) ?? p.message}</AlertDescription>
            </AlertContent>
          </Alert>
        ))}
        {previewError ? (
          <Alert variant="destructive" className="rounded-2xl">
            <AlertIcon />
            <AlertContent>
              <AlertDescription>{previewError}</AlertDescription>
            </AlertContent>
          </Alert>
        ) : null}
      </div>

      <Group>
        <Row>
          <span className="flex flex-1 flex-col">
            <span className="text-[15px]">{T.sign}</span>
            <span className="text-[12px] text-muted-foreground">{signing ? T.signNote : T.signOffNote}</span>
          </span>
          <Switch checked={signing} onCheckedChange={(on) => void setSigning(on)} ariaLabel={T.sign} />
        </Row>
      </Group>

      <Collapsible>
        <CollapsibleTrigger className="min-h-12 rounded-2xl px-4 text-[15px] font-normal text-muted-foreground hover:bg-hover">
          {T.more}
          <CollapsibleIndicator />
        </CollapsibleTrigger>
        <CollapsibleContent contentClassName="flex flex-col gap-4 pt-3 pb-1">
          {!probeOn && usable.length ? (
            <div className="flex flex-col gap-1.5">
              <Label id="make-replaces-label">{T.replaces}</Label>
              <Picker
                label={T.replaces}
                labelId="make-replaces-label"
                value={validReplacing || "none"}
                onChange={(v) => setReplaces(v === "none" ? "" : v)}
                options={[
                  { value: "none", label: T.replacesNone },
                  ...usable.map((t) => ({ value: t.id, label: `${t.label} · ${stateLabel(T, t.state)}` })),
                ]}
              />
              <Note>{T.replacesNote}</Note>
            </div>
          ) : null}
          <Input
            label={T.gatewayUrl}
            autoComplete="off"
            spellCheck={false}
            placeholder={state.gatewayUrl}
            value={url}
            onChange={setUrl}
            className="font-mono"
            classNames={{ label: "font-sans text-[13px] text-muted-foreground", input: "text-[14px]" }}
          />
          {/* The wait test is a device-session tool, shown only while the gateway serves it. */}
          {state.probe.enabled ? (
            <Group>
              <Row>
                <span className="flex-1 text-[15px]">{T.probe}</span>
                <Switch checked={probe} onCheckedChange={setProbe} ariaLabel={T.probe} />
              </Row>
            </Group>
          ) : null}
        </CollapsibleContent>
      </Collapsible>

      <div className="flex justify-end">
        <StatefulButton
          size="lg"
          state={btn}
          disabled={!bot || !current || blocking || previewError !== null}
          loadingText={T.building}
          successText={T.built}
          errorText={T.retry}
          onClick={() => void make()}
          className="min-w-44"
        >
          {T.build}
        </StatefulButton>
      </div>
    </div>
  );
}
