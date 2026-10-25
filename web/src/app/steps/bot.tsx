import { useState } from "react";
import { Bot, ShieldCheck, Trash2 } from "lucide-react";
import { AnimatePresence, motion } from "motion/react";
import { Input } from "@/components/motion/input";
import { Switch } from "@/components/motion/switch";
import { StatefulButton, type ButtonState } from "@/components/motion/button/stateful";
import { Button } from "@/components/motion/button/base";
import { AnimatedBadge } from "@/components/motion/animated-badge";
import { Collapsible, CollapsibleContent, CollapsibleIndicator, CollapsibleTrigger } from "@/components/motion/collapsible";
import { TextShimmer } from "@/components/motion/text-shimmer";
import { api, type SetupState } from "@/api";
import { fmt } from "@/i18n";
import { useSetup } from "../setup";
import { Group, Note, Row, StepHeader } from "../pieces";
import { GrokBotAvatar } from "../brand";

export function BotStep({ onDone }: { onDone: () => void }) {
  const { state, T, setState, run, confirm } = useSetup();
  const [name, setName] = useState("");
  const [again, setAgain] = useState("");
  const [sid, setSid] = useState("");
  const [sidName, setSidName] = useState("");
  // Each form has its own switch: consent given for one bot never carries over to another.
  const [strict, setStrict] = useState(true);
  const [sidStrict, setSidStrict] = useState(true);
  const [btn, setBtn] = useState<ButtonState>("idle");
  const [sidBtn, setSidBtn] = useState<ButtonState>("idle");
  if (!state) return null;
  const bots = state.bots;

  const mismatch = again.length > 0 && again.trim() !== name.trim();

  /** Strict checking off needs an explicit "yes" after the privacy warning (DESIGN §4.2). */
  const toggleStrict = (set: (on: boolean) => void) => async (on: boolean) => {
    if (on) return set(true);
    if (await confirm({ title: T.confirmNonStrict, body: T.confirmNonStrictBody, action: T.turnOff })) set(false);
  };
  const strictFields = (on: boolean) => (on ? { strictEcho: true } : { strictEcho: false, confirmNonStrict: true });
  const strictRow = (on: boolean, set: (on: boolean) => void) => (
    <Group className="mt-2">
      <Row>
        <ShieldCheck className="size-5 text-emerald-600 dark:text-emerald-400" />
        <span className="flex-1 text-[15px]">{T.strict}</span>
        <AnimatedBadge status="success" size="sm" showIcon={false} className="hidden sm:inline-flex">
          {T.recommended}
        </AnimatedBadge>
        <Switch checked={on} onCheckedChange={(v) => void toggleStrict(set)(v)} ariaLabel={T.strict} />
      </Row>
    </Group>
  );

  const added = (s: SetupState, set: (b: ButtonState) => void) => {
    setState(s);
    set("success");
    window.setTimeout(() => set("idle"), 1400);
    setStrict(true);
    setSidStrict(true);
  };

  const addByName = async () => {
    setBtn("loading");
    const s = await run(() => api<SetupState>("/api/bots/by-name", { name: name.trim(), confirmName: again.trim(), ...strictFields(strict) }));
    if (!s) return setBtn("error");
    setName("");
    setAgain("");
    added(s, setBtn);
  };

  const addBySession = async () => {
    setSidBtn("loading");
    const s = await run(() => api<SetupState>("/api/bots", { sessionId: sid.trim(), name: sidName.trim(), ...strictFields(sidStrict) }));
    if (!s) return setSidBtn("error");
    setSid("");
    setSidName("");
    added(s, setSidBtn);
  };

  const remove = async (key: string, botName: string) => {
    if (!(await confirm({ title: fmt(T.confirmRemoveBot, { name: botName }), body: T.confirmRemoveBotBody, action: T.removeBot }))) return;
    const s = await run(() => api<SetupState>(`/api/bots/${encodeURIComponent(key)}/remove`, {}), { done: T.saved });
    if (s) setState(s);
  };

  const addForm = (
    <form
      className="flex flex-col gap-3"
      onSubmit={(e) => {
        e.preventDefault();
        if (name.trim() && !mismatch && again.trim()) void addByName();
      }}
    >
      <div className="grid gap-3 sm:grid-cols-2">
        <Input
          label={T.botName}
          placeholder={T.botNamePlaceholder}
          maxLength={60}
          autoComplete="off"
          spellCheck={false}
          value={name}
          onChange={(v) => {
            setName(v);
            if (btn === "error") setBtn("idle");
          }}
          classNames={{ label: "text-[13px] text-muted-foreground" }}
        />
        <Input
          label={T.botConfirm}
          placeholder={T.botConfirmPlaceholder}
          maxLength={60}
          autoComplete="off"
          spellCheck={false}
          value={again}
          onChange={setAgain}
          error={mismatch}
          success={again.trim().length > 0 && again.trim() === name.trim()}
          classNames={{ label: "text-[13px] text-muted-foreground" }}
        />
      </div>
      <Note>{T.botNameNote}</Note>

      {strictRow(strict, setStrict)}

      <div className="flex items-center justify-end gap-3 pt-2">
        {btn === "loading" ? <TextShimmer className="text-[13px]">{T.adding}</TextShimmer> : null}
        <StatefulButton
          type="submit"
          variant={bots.length ? "secondary" : "primary"}
          state={btn}
          disabled={!name.trim() || !again.trim() || mismatch}
          loadingText={T.add}
          successText={T.saved}
          errorText={T.retry}
          className="min-w-28"
        >
          {T.add}
        </StatefulButton>
      </div>
    </form>
  );

  return (
    <div className="flex flex-col gap-8">
      <StepHeader icon={Bot} tint="bg-gradient-to-b from-emerald-400 to-teal-600" title={T.botTitle} />

      {bots.length ? (
        <Group>
          <AnimatePresence initial={false}>
            {bots.map((b) => (
              <motion.div
                key={b.key}
                layout
                initial={{ opacity: 0, height: 0 }}
                animate={{ opacity: 1, height: "auto" }}
                exit={{ opacity: 0, height: 0 }}
                transition={{ type: "spring", bounce: 0.2, duration: 0.45 }}
              >
                <Row>
                  <GrokBotAvatar still className="size-9 shrink-0 align-middle" />
                  <div className="flex min-w-0 flex-1 flex-col">
                    <span className="truncate text-[15px] font-medium">{b.name}</span>
                    <span className="truncate font-mono text-[11px] text-muted-foreground">{b.sessionId}</span>
                  </div>
                  {!b.strictEcho ? (
                    <AnimatedBadge status="warning" size="sm">
                      {T.strictOff}
                    </AnimatedBadge>
                  ) : null}
                  <Button variant="ghost" size="icon" aria-label={T.removeBot} onClick={() => void remove(b.key, b.name)}>
                    <Trash2 className="size-4" />
                  </Button>
                </Row>
              </motion.div>
            ))}
          </AnimatePresence>
        </Group>
      ) : null}

      {/* With a bot in place, both ways to add another fold into one quiet list. */}
      {bots.length ? null : addForm}
      <div className="flex flex-col gap-1">
        {bots.length ? (
          <Collapsible>
            <CollapsibleTrigger className="min-h-12 rounded-2xl px-4 text-[15px] font-normal text-muted-foreground hover:bg-hover">
              {T.addAnother}
              <CollapsibleIndicator />
            </CollapsibleTrigger>
            <CollapsibleContent contentClassName="pt-3 pb-4">{addForm}</CollapsibleContent>
          </Collapsible>
        ) : null}
          <Collapsible>
            <CollapsibleTrigger className="min-h-12 rounded-2xl px-4 text-[15px] font-normal text-muted-foreground hover:bg-hover">
              {T.bySession}
              <CollapsibleIndicator />
            </CollapsibleTrigger>
            <CollapsibleContent contentClassName="pt-3 pb-4">
              <form
                className="flex flex-col gap-3"
                onSubmit={(e) => {
                  e.preventDefault();
                  if (/^\d+$/.test(sid.trim()) && sidName.trim()) void addBySession();
                }}
              >
                <div className="grid gap-3 sm:grid-cols-2">
                  <Input label={T.sessionId} inputMode="numeric" autoComplete="off" value={sid} onChange={setSid} classNames={{ label: "text-[13px] text-muted-foreground" }} />
                  <Input label={T.spokenName} maxLength={60} autoComplete="off" value={sidName} onChange={setSidName} classNames={{ label: "text-[13px] text-muted-foreground" }} />
                </div>
                {strictRow(sidStrict, setSidStrict)}
                <div className="flex justify-end">
                  <StatefulButton
                    type="submit"
                    variant="secondary"
                    state={sidBtn}
                    disabled={!/^\d+$/.test(sid.trim()) || !sidName.trim()}
                    loadingText={T.add}
                    successText={T.saved}
                    errorText={T.retry}
                    className="min-w-28"
                  >
                    {T.add}
                  </StatefulButton>
                </div>
              </form>
            </CollapsibleContent>
          </Collapsible>
      </div>


      {bots.length ? (
        <div className="flex justify-end">
          <Button onClick={onDone} className="min-w-28">
            {T.next}
          </Button>
        </div>
      ) : null}
    </div>
  );
}
