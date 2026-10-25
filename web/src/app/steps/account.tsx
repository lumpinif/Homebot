import { useEffect, useRef, useState } from "react";
import { ArrowUpRight, KeyRound, Link2 } from "lucide-react";
import { AnimatePresence, motion } from "motion/react";
import { Input } from "@/components/motion/input";
import { StatefulButton, type ButtonState } from "@/components/motion/button/stateful";
import { Button } from "@/components/motion/button/base";
import { AnimatedBadge } from "@/components/motion/animated-badge";
import { api, type SetupState } from "@/api";
import { fmt } from "@/i18n";
import { useSetup } from "../setup";
import { Group, Note, Row, StepHeader } from "../pieces";
import { CursorMark } from "../brand";

// Where Cursor lists User API Keys. Not yet confirmed against the live dashboard (STATUS).
export const CURSOR_KEYS_URL = "https://cursor.com/dashboard?tab=integrations";

export function AccountStep({ onDone }: { onDone: () => void }) {
  const { state, T, setState, run } = useSetup();
  const [key, setKey] = useState("");
  const [btn, setBtn] = useState<ButtonState>("idle");
  const [editing, setEditing] = useState(false);
  const c = state?.credential ?? null;
  const timer = useRef(0);
  useEffect(() => () => window.clearTimeout(timer.current), []);

  const save = async () => {
    setBtn("loading");
    const s = await run(() => api<SetupState>("/api/credential", { key }));
    if (!s) return setBtn("error");
    setState(s);
    setKey("");
    setBtn("success");
    timer.current = window.setTimeout(() => {
      setEditing(false);
      setBtn("idle");
      onDone();
    }, 700);
  };

  const remove = async () => {
    const s = await run(() => api<SetupState>("/api/credential/remove", {}), { done: T.saved });
    if (s) setState(s);
  };

  const which = !c ? "" : c.kind === "env" ? fmt(T.keyEnv, { name: c.source.slice(4) }) : c.kind === "saved" ? T.keySaved : T.keyDetected;
  const showForm = !c || editing;

  return (
    <div className="flex flex-col gap-8">
      <StepHeader icon={Link2} tint="bg-gradient-to-b from-sky-400 to-blue-600" title={T.accountTitle} />
      <AnimatePresence mode="wait" initial={false}>
        {showForm ? (
          <motion.form
            key="form"
            initial={{ opacity: 0, y: 8 }}
            animate={{ opacity: 1, y: 0 }}
            exit={{ opacity: 0, y: -8 }}
            transition={{ duration: 0.22 }}
            className="flex flex-col gap-3"
            onSubmit={(e) => {
              e.preventDefault();
              if (key.trim()) void save();
            }}
          >
            <Input
              label={T.apiKey}
              type="password"
              autoComplete="off"
              spellCheck={false}
              placeholder={T.apiKeyPlaceholder}
              value={key}
              onChange={(v) => {
                setKey(v);
                if (btn === "error") setBtn("idle");
              }}
              leftIcon={<KeyRound />}
              error={btn === "error"}
              classNames={{ label: "text-[13px] text-muted-foreground" }}
            />
            <p className="flex flex-wrap items-center gap-x-1 px-1 text-[13px] leading-snug text-muted-foreground">
              {T.apiKeyIn}
              <a
                href={CURSOR_KEYS_URL}
                target="_blank"
                rel="noopener noreferrer"
                className="inline-flex items-center gap-1 font-medium text-foreground underline-offset-[3px] outline-none hover:underline focus-visible:underline"
              >
                <CursorMark className="size-3.5" />
                {T.cursorDashboard}
              </a>
              <span>· {T.apiKeyStays}</span>
            </p>
            <div className="flex items-center justify-end gap-2 pt-2">
              <Button
                type="button"
                variant="secondary"
                className="mr-auto"
                onClick={() => window.open(CURSOR_KEYS_URL, "_blank", "noopener,noreferrer")}
              >
                {T.apiKeyCreate}
                <ArrowUpRight className="size-4" />
              </Button>
              {c ? (
                <Button type="button" variant="ghost" onClick={() => setEditing(false)}>
                  {T.cancel}
                </Button>
              ) : null}
              <StatefulButton type="submit" state={btn} disabled={!key.trim()} loadingText={T.saving} successText={T.saved} errorText={T.retry} className="min-w-28">
                {T.save}
              </StatefulButton>
            </div>
          </motion.form>
        ) : c ? (
          <motion.div
            key="status"
            initial={{ opacity: 0, y: 8 }}
            animate={{ opacity: 1, y: 0 }}
            exit={{ opacity: 0, y: -8 }}
            transition={{ duration: 0.22 }}
            className="flex flex-col gap-3"
          >
            <Group>
              <Row>
                <KeyRound className="size-5 text-muted-foreground" />
                <span className="min-w-0 flex-1 truncate text-[15px]">{which}</span>
                <AnimatedBadge
                  status={c.access === "ok" ? "success" : c.access === "rejected" ? "danger" : "neutral"}
                  contentKey={c.access}
                >
                  {c.access === "ok" ? T.accessOk : c.access === "rejected" ? T.accessRejected : T.accessUnchecked}
                </AnimatedBadge>
              </Row>
            </Group>
            {c.kind === "env" ? <Note>{T.keyEnvNote}</Note> : null}
            {c.kind === "detected" ? <Note>{T.keyDetectedNote}</Note> : null}
            <div className="flex flex-wrap justify-end gap-2 pt-2">
              {c.kind === "saved" ? (
                <Button variant="ghost" onClick={() => void remove()}>
                  {T.removeKey}
                </Button>
              ) : null}
              {c.kind !== "env" ? (
                <Button variant="secondary" onClick={() => setEditing(true)}>
                  {T.replaceKey}
                </Button>
              ) : null}
              <Button onClick={onDone} className="min-w-28">
                {T.next}
              </Button>
            </div>
          </motion.div>
        ) : null}
      </AnimatePresence>
    </div>
  );
}
