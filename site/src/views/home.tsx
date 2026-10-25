// Home: the product in one page. The headline, one question travelling from Siri to the Grok Bot
// and back, what you can ask, and how to get it running. Few words; space between sections.
import { ArrowDownToLine, ChevronRight } from "lucide-react";
import type { ReactNode } from "react";
import { cn } from "@/lib/utils";
import { useT } from "@/i18n";
import { downloadUrl, useGo } from "@/state";
import { GrokBotAvatar, SiriOrb } from "@/ui/brand";
import { AgentPrompt } from "@/ui/agent";
import { Flow } from "./flow";

export function HomeView() {
  const { t } = useT();
  const go = useGo();
  const parts = t.hero.split(/(\{grok\}|\{siri\})/);
  return (
    <div className="flex flex-col gap-32 pt-14 sm:gap-40 sm:pt-20">
      <section className="flex flex-col items-center text-center">
        <h1 className="text-[40px] leading-[1.08] font-bold tracking-[-0.03em] text-balance sm:text-[56px]">
          {parts.map((p, i) =>
            p === "{grok}" ? (
              <span key={i} className="whitespace-nowrap">
                <GrokBotAvatar className="mr-[0.18em] align-[-0.1em]" />
                Grok Bot
              </span>
            ) : p === "{siri}" ? (
              <span key={i} className="whitespace-nowrap">
                <SiriOrb className="mr-[0.18em] size-[0.9em] align-[-0.1em]" />
                Siri
              </span>
            ) : (
              <span key={i}>{p}</span>
            ),
          )}
        </h1>
        <p className="mt-6 max-w-[500px] text-[19px] leading-snug text-label-2 text-balance sm:text-[21px]">{t.heroSub}</p>
        <div className="mt-9 flex flex-wrap items-center justify-center gap-x-6 gap-y-3">
          <a
            href={downloadUrl("home")}
            className="inline-flex h-11 items-center gap-2 rounded-full bg-accent-fill px-6 text-[16px] font-medium text-white transition-colors hover:bg-[color-mix(in_srgb,var(--accent-fill),black_10%)]"
          >
            <ArrowDownToLine className="size-[18px]" strokeWidth={2.2} />
            {t.download}
          </a>
          <TextLink onClick={() => go("install")}>{t.howMore}</TextLink>
        </div>
        <p className="mt-5 text-[13px] text-label-3">
          {t.requires} · {t.heroMeta}
        </p>
      </section>

      {/* The demo belongs to the hero: closer to it than the sections are to each other. */}
      <div className="-mt-12 sm:-mt-20">
        <Flow />
      </div>

      <section aria-labelledby="ask" className="flex flex-col items-center">
        <Heading id="ask" title={t.askTitle} sub={t.askSub} />
        <ul className="mt-14 grid w-full gap-10 sm:grid-cols-3 sm:gap-8">
          {t.examples.map(([q, a]) => (
            <li key={q} className="flex flex-col gap-3">
              <p className="text-[19px] leading-snug font-semibold tracking-[-0.01em] text-balance">“{q}”</p>
              <p className="flex gap-2 text-[15px] leading-snug text-label-2">
                <SiriOrb className="mt-[2px] size-[16px]" active={false} />
                <span>{a}</span>
              </p>
            </li>
          ))}
        </ul>
      </section>

      <section aria-labelledby="how" className="flex flex-col items-center">
        <Heading id="how" title={t.howTitle} />
        <ol className="mt-14 grid w-full gap-10 sm:grid-cols-3 sm:gap-8">
          {[
            [t.how1, t.how1Note],
            [t.how2, t.how2Note],
            [t.how3, t.how3Note],
          ].map(([title, note], i) => (
            <li key={i} className="flex flex-col items-center gap-2 text-center">
              <span className="text-[44px] leading-none font-semibold tracking-[-0.03em] text-label-3 tabular-nums">{i + 1}</span>
              <span className="mt-2 text-[19px] font-semibold">{title}</span>
              <span className="text-[15px] text-label-2 text-balance">{note}</span>
            </li>
          ))}
        </ol>
        <div className="mt-10">
          <TextLink onClick={() => go("install")}>{t.howMore}</TextLink>
        </div>
        <div className="mt-20 w-full">
          <AgentPrompt />
        </div>
      </section>
    </div>
  );
}

export function Heading({ id, title, sub }: { id?: string; title: string; sub?: string }) {
  return (
    <div className="flex flex-col items-center text-center">
      <h2 id={id} className="text-[32px] leading-[1.1] font-bold tracking-[-0.025em] text-balance sm:text-[40px]">
        {title}
      </h2>
      {sub && <p className="mt-4 max-w-[520px] text-[17px] leading-snug text-label-2 text-balance sm:text-[19px]">{sub}</p>}
    </div>
  );
}

export function TextLink({ onClick, href, children }: { onClick?: () => void; href?: string; children: ReactNode }) {
  const cls = "inline-flex items-center gap-0.5 text-[16px] text-accent transition-colors hover:text-[color-mix(in_srgb,var(--accent),black_18%)]";
  const inner = (
    <>
      {children}
      <ChevronRight className="size-4" strokeWidth={2.2} />
    </>
  );
  return href ? (
    <a href={href} className={cls}>
      {inner}
    </a>
  ) : (
    <button onClick={onClick} className={cn(cls, "link")}>
      {inner}
    </button>
  );
}
