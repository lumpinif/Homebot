import { AudioLines, FolderOpen, RefreshCw, Trash2 } from "lucide-react";
import { AnimatePresence, motion } from "motion/react";
import { Button } from "@/components/motion/button/base";
import { AnimatedBadge } from "@/components/motion/animated-badge";
import { Collapsible, CollapsibleContent, CollapsibleIndicator, CollapsibleTrigger } from "@/components/motion/collapsible";
import { Tooltip, TooltipContent, TooltipTrigger } from "@/components/motion/tooltip";
import { api, type SetupState, type TokenView } from "@/api";
import { fmt } from "@/i18n";
import { useLangName, useSetup } from "./setup";

function ShortcutRow({ t, onReplace }: { t: TokenView; onReplace: (t: TokenView) => void }) {
  const { state, T, lang, setState, run, confirm } = useSetup();
  const langName = useLangName();
  const bot = state?.bots.find((b) => b.key === t.bot);
  const retired = t.state === "retired";

  const revoke = async () => {
    if (!(await confirm({ title: fmt(T.confirmRevoke, { name: t.label }), body: T.confirmRevokeBody, action: T.revoke }))) return;
    const s = await run(() => api<SetupState>(`/api/tokens/${t.id}/revoke`, {}), { done: T.saved });
    if (s) setState(s);
  };

  return (
    <motion.li
      layout
      initial={{ opacity: 0, y: 8 }}
      animate={{ opacity: 1, y: 0 }}
      exit={{ opacity: 0, scale: 0.96 }}
      transition={{ type: "spring", bounce: 0.2, duration: 0.45 }}
      className="flex flex-col gap-3 rounded-2xl border border-border bg-card p-4 sm:flex-row sm:items-center"
    >
      <span className={retired ? "grid size-11 shrink-0 place-items-center rounded-xl bg-muted text-muted-foreground" : "grid size-11 shrink-0 place-items-center rounded-xl bg-gradient-to-b from-pink-400 to-fuchsia-600 text-white shadow-sm"}>
        <AudioLines className="size-5" />
      </span>
      <div className="flex min-w-0 flex-1 flex-col gap-0.5">
        <span className={retired ? "truncate text-[16px] font-medium text-muted-foreground line-through decoration-1" : "truncate text-[16px] font-medium"}>{t.label}</span>
        <span className="truncate text-[12px] text-muted-foreground">
          {[bot?.name ?? t.bot, langName(t.siriLang), new Date(t.createdAt).toLocaleDateString(lang)].join(" · ")}
        </span>
      </div>
      <div className="flex flex-wrap items-center gap-1.5">
        {t.kind !== "ask" ? (
          <AnimatedBadge status="info" size="sm" showIcon={false}>
            {t.kind === "probe" ? T.kindProbe : T.kindLab}
          </AnimatedBadge>
        ) : null}
        {t.languageDiffers && !retired ? (
          <AnimatedBadge status="warning" size="sm">
            {fmt(T.langDiffers, { lang: langName(t.siriLang) })}
          </AnimatedBadge>
        ) : null}
        <AnimatedBadge status={t.state === "active" ? "success" : "neutral"} size="sm" pulse={t.state === "pending"} contentKey={t.state}>
          {t.state === "active" ? T.stateActive : t.state === "pending" ? T.statePending : T.stateRetired}
        </AnimatedBadge>
        {t.languageDiffers && bot && !retired ? (
          <Button size="sm" variant="secondary" onClick={() => onReplace(t)}>
            <RefreshCw className="size-3.5" />
            {T.replace}
          </Button>
        ) : null}
        {t.hasFile ? (
          <Tooltip>
            <TooltipTrigger asChild>
              <Button size="icon" variant="ghost" aria-label={T.finder} onClick={() => void run(() => api(`/api/shortcuts/${t.id}/reveal`, {}))}>
                <FolderOpen className="size-4" />
              </Button>
            </TooltipTrigger>
            <TooltipContent>{T.finder}</TooltipContent>
          </Tooltip>
        ) : null}
        {!retired ? (
          <Tooltip>
            <TooltipTrigger asChild>
              <Button size="icon" variant="ghost" aria-label={T.revoke} onClick={() => void revoke()} className="hover:text-destructive">
                <Trash2 className="size-4" />
              </Button>
            </TooltipTrigger>
            <TooltipContent>{T.revoke}</TooltipContent>
          </Tooltip>
        ) : null}
      </div>
    </motion.li>
  );
}

export function ShortcutsView({ onReplace, onMake }: { onReplace: (t: TokenView) => void; onMake: () => void }) {
  const { state, T } = useSetup();
  if (!state) return null;
  const all = [...state.tokens].reverse();
  const live = all.filter((t) => t.state !== "retired");
  const old = all.filter((t) => t.state === "retired");

  return (
    <div className="flex flex-col gap-6">
      <h2 className="px-1 text-[28px] leading-tight font-semibold tracking-tight">{T.shortcutsTitle}</h2>
      {live.length ? (
        <ul className="flex flex-col gap-2.5">
          <AnimatePresence initial={false}>
            {live.map((t) => (
              <ShortcutRow key={t.id} t={t} onReplace={onReplace} />
            ))}
          </AnimatePresence>
        </ul>
      ) : (
        <div className="flex flex-col items-center gap-4 rounded-3xl border border-dashed border-border py-14">
          <span className="grid size-14 place-items-center rounded-2xl bg-muted text-muted-foreground">
            <AudioLines className="size-7" />
          </span>
          <p className="text-[15px] text-muted-foreground">{T.shortcutsNone}</p>
          <Button onClick={onMake}>{T.makeOne}</Button>
        </div>
      )}
      {/* Retired Shortcuts no longer work: kept for reference, folded away. */}
      {old.length ? (
        <Collapsible>
          <CollapsibleTrigger className="min-h-12 rounded-2xl px-4 text-[15px] font-normal text-muted-foreground hover:bg-hover">
            {fmt(T.retired, { n: old.length })}
            <CollapsibleIndicator />
          </CollapsibleTrigger>
          <CollapsibleContent contentClassName="pt-3">
            <ul className="flex flex-col gap-2.5">
              {old.map((t) => (
                <ShortcutRow key={t.id} t={t} onReplace={onReplace} />
              ))}
            </ul>
          </CollapsibleContent>
        </Collapsible>
      ) : null}
    </div>
  );
}
