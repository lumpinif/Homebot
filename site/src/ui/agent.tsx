// "Have an AI agent?": one short prompt to paste into an agent. It points at install.md, the
// agent-facing guide this site serves, which marks the steps the person does themselves.
import { useEffect, useState } from "react";
import { Check as CheckIcon, Copy, Sparkles } from "lucide-react";
import { fmt, useT } from "@/i18n";
import { Button } from "@/ui/kit";

/** The guide's address wherever the site is hosted (base "./"), without the view's hash. */
export const guideUrl = () => new URL("install.md", location.href.split("#")[0]).href;

/** True when the text reached the clipboard. */
async function copyText(text: string): Promise<boolean> {
  try {
    await navigator.clipboard.writeText(text);
    return true;
  } catch {
    // Older browsers, or no permission: the hidden textarea route, then focus goes back.
    const back = document.activeElement as HTMLElement | null;
    const ta = document.createElement("textarea");
    ta.value = text;
    ta.setAttribute("readonly", "");
    ta.style.position = "fixed";
    ta.style.opacity = "0";
    document.body.append(ta);
    ta.select();
    let ok = false;
    try {
      ok = document.execCommand("copy");
    } catch {
      ok = false;
    }
    ta.remove();
    back?.focus();
    return ok;
  }
}

/** The prompt, always in view, with one Copy button. */
export function AgentPrompt() {
  const { t } = useT();
  const [copied, setCopied] = useState<"no" | "yes" | "failed">("no");
  const text = fmt(t.agentPrompt, { url: guideUrl() });
  useEffect(() => {
    if (copied !== "yes") return;
    const id = setTimeout(() => setCopied("no"), 1800);
    return () => clearTimeout(id);
  }, [copied]);
  return (
    <div className="flex flex-col gap-4">
      <div className="flex items-start gap-3">
        <span className="grid size-8 shrink-0 place-items-center rounded-[9px] bg-[linear-gradient(180deg,#5e5ce6,#3634a3)] text-white">
          <Sparkles className="size-[17px]" strokeWidth={2} />
        </span>
        <div className="min-w-0 flex-1">
          <h3 className="text-[17px] font-semibold">{t.agentTitle}</h3>
          <p className="text-[15px] text-label-2">{t.agentNote}</p>
        </div>
      </div>
      <div className="relative rounded-[14px] bg-fill-2 p-4 pr-[112px] max-sm:pr-4 max-sm:pb-14">
        <p className="font-mono text-[13px] leading-relaxed break-words text-label select-all">{text}</p>
        <Button
          kind="primary"
          onClick={() => copyText(text).then((ok) => setCopied(ok ? "yes" : "failed"))}
          className="absolute right-3 bottom-3 w-[88px] sm:top-3 sm:bottom-auto"
        >
          {copied === "yes" ? <CheckIcon className="size-3.5" strokeWidth={2.6} /> : <Copy className="size-3.5" strokeWidth={2.2} />}
          {copied === "yes" ? t.copied : t.copy}
        </Button>
      </div>
      <span role="status" className="sr-only">
        {copied === "yes" ? t.copied : copied === "failed" ? t.copyFailed : ""}
      </span>
      {copied === "failed" && <p className="-mt-2 text-[13px] text-label-2">{t.copyFailed}</p>}
    </div>
  );
}
