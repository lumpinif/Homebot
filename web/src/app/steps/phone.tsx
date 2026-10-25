import { useState } from "react";
import { FolderOpen, QrCode, Smartphone, TriangleAlert } from "lucide-react";
import { AnimatePresence, motion } from "motion/react";
import { Card } from "@/components/motion/card";
import { Button } from "@/components/motion/button/base";
import { Loader } from "@/components/motion/loader";
import { api, type DownloadLink } from "@/api";
import { fmt } from "@/i18n";
import { useSetup } from "../setup";
import { StepHeader } from "../pieces";

/** QR modules as SVG squares (no inline styles or data: URLs, per the page's CSP). */
function Qr({ rows }: { rows: string[] }) {
  const n = rows.length;
  const quiet = 3;
  const size = n + quiet * 2;
  const d = rows.flatMap((row, y) => [...row].flatMap((c, x) => (c === "1" ? [`M${x + quiet} ${y + quiet}h1v1h-1z`] : []))).join("");
  return (
    <svg viewBox={`0 0 ${size} ${size}`} className="size-52 rounded-2xl bg-white" role="img" shapeRendering="crispEdges">
      <path d={d} fill="#000" />
    </svg>
  );
}

export function PhoneStep({ onMake }: { onMake: () => void }) {
  const { state, T, build, run } = useSetup();
  const [link, setLink] = useState<DownloadLink | null>(null);
  const [linking, setLinking] = useState(false);
  const [shownFor, setShownFor] = useState<string | null>(null);
  // A new build drops the previous link.
  if (build && shownFor !== build.tokenId) {
    setShownFor(build.tokenId);
    setLink(null);
  }

  if (!build) {
    // Made on an earlier visit and not used yet: the file may still be here to send.
    const waiting = [...(state?.tokens ?? [])].reverse().find((t) => t.kind === "ask" && t.state === "pending");
    return (
      <div className="flex flex-col gap-8">
        <StepHeader icon={Smartphone} tint="bg-gradient-to-b from-zinc-400 to-zinc-700" title={T.phoneTitle} />
        <div className="flex flex-col items-center gap-4 py-6 text-center">
          <p className="text-[15px] text-muted-foreground">{waiting ? fmt(T.phoneWaiting, { name: waiting.label }) : T.phoneEmpty}</p>
          <div className="flex flex-wrap justify-center gap-2">
            {waiting?.hasFile ? (
              <Button variant="secondary" onClick={() => void run(() => api(`/api/shortcuts/${waiting.id}/reveal`, {}))}>
                <FolderOpen className="size-4" />
                {T.airdropNote}
              </Button>
            ) : null}
            <Button onClick={onMake}>{waiting ? T.makeAgain : T.build}</Button>
          </div>
        </div>
      </div>
    );
  }

  // Each press asks for a fresh link: a link works once and expires in ten minutes.
  const showLink = async () => {
    if (linking) return;
    setLinking(true);
    const l = await run(() => api<DownloadLink>(`/api/shortcuts/${build.tokenId}/link`, {}));
    setLinking(false);
    if (l) setLink(l);
  };

  return (
    <div className="flex flex-col gap-8">
      <StepHeader icon={Smartphone} tint="bg-gradient-to-b from-zinc-400 to-zinc-700" title={T.phoneTitle}>
        <p className="text-[17px] font-medium">{fmt(build.signed ? T.madeSigned : T.madeUnsigned, { name: build.name })}</p>
      </StepHeader>

      {!build.signed ? (
        <div className="flex items-start gap-3 rounded-2xl bg-amber-500/10 px-4 py-3 text-amber-800 dark:text-amber-300">
          <TriangleAlert className="mt-0.5 size-4 shrink-0" />
          <p className="text-[14px]">{T.madeUnsignedNote}</p>
        </div>
      ) : null}

      <div className="grid gap-3 sm:grid-cols-2">
        <Card interactive size="compact" className="items-center text-center">
          <button type="button" onClick={() => void run(() => api(`/api/shortcuts/${build.tokenId}/reveal`, {}))} className="flex flex-col items-center gap-2 outline-none after:absolute after:inset-0">
            <span className="grid size-12 place-items-center rounded-full bg-sky-500/10 text-sky-600 dark:text-sky-400">
              <FolderOpen className="size-6" />
            </span>
            <span className="text-[15px] font-medium">{T.airdrop}</span>
            <span className="text-[12px] text-muted-foreground">{T.airdropNote}</span>
          </button>
        </Card>
        {/* A download link for a file iOS won't import only leads to an error on the phone. */}
        <Card interactive={build.signed} size="compact" className={build.signed ? "items-center text-center" : "items-center text-center opacity-50"}>
          <button type="button" disabled={!build.signed} onClick={() => void showLink()} className="flex flex-col items-center gap-2 outline-none after:absolute after:inset-0">
            <span className="grid size-12 place-items-center rounded-full bg-violet-500/10 text-violet-600 dark:text-violet-400">
              {linking ? <Loader size={22} /> : <QrCode className="size-6" />}
            </span>
            <span className="text-[15px] font-medium">{T.scan}</span>
            <span className="text-[12px] text-muted-foreground">{T.scanNote}</span>
          </button>
        </Card>
      </div>

      <AnimatePresence initial={false}>
        {link ? (
          <motion.div
            key="qr"
            initial={{ opacity: 0, scale: 0.92, height: 0 }}
            animate={{ opacity: 1, scale: 1, height: "auto" }}
            exit={{ opacity: 0, scale: 0.92, height: 0 }}
            transition={{ type: "spring", bounce: 0.25, duration: 0.5 }}
            className="flex flex-col items-center gap-3 overflow-hidden"
          >
            <div className="rounded-3xl border border-border bg-white p-3 shadow-sm">
              <Qr rows={link.qr} />
            </div>
            <p className="text-[13px] text-muted-foreground">{T.qrNote}</p>
            <p className="text-[12px] text-muted-foreground tabular-nums">{fmt(T.expires, { time: new Date(link.expiresAt).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" }) })}</p>
          </motion.div>
        ) : null}
      </AnimatePresence>

      {/* The steps stay in the iPhone's language: they name iOS settings as shown there. */}
      <div className="flex flex-col gap-3">
        <p className="px-1 text-[13px] font-medium text-muted-foreground">{T.onIphone}</p>
        <ol className="flex flex-col gap-2">
          {build.steps.map((s, i) => (
            <motion.li
              key={s}
              initial={{ opacity: 0, x: -8 }}
              animate={{ opacity: 1, x: 0 }}
              transition={{ delay: 0.05 * i, duration: 0.3 }}
              className="flex items-start gap-3 rounded-2xl border border-border bg-card px-4 py-3"
            >
              <span className="grid size-6 shrink-0 place-items-center rounded-full bg-foreground text-[12px] font-semibold text-background tabular-nums">{i + 1}</span>
              <span className="text-[14px] leading-relaxed">{s}</span>
            </motion.li>
          ))}
        </ol>
      </div>
    </div>
  );
}
