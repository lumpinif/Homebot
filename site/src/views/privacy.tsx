// Privacy: what stays on the Mac, what leaves it, and the home network in three short statements,
// then the full policy (downloads, update check, opt-in counts, email) in plain words.
import { Cloud, House, Laptop } from "lucide-react";
import type { ReactNode } from "react";
import { fmt, useT } from "@/i18n";
import { Heading } from "./home";

const POLICY_DATE = "2026-10-25";
const POLICY_EMAIL = "privacy@homebot.fun";
// The data controller (Felix, decision D12).
const CONTROLLER = "Felix Lyu";

export function PrivacyView() {
  const { t } = useT();
  const items: [ReactNode, string, string][] = [
    [<Laptop key="s" className="size-[26px]" strokeWidth={1.6} />, t.staysTitle, t.staysBody],
    [<Cloud key="l" className="size-[26px]" strokeWidth={1.6} />, t.leavesTitle, t.leavesBody],
    [<House key="n" className="size-[26px]" strokeWidth={1.6} />, t.networkTitle, t.networkBody],
  ];
  return (
    <div className="flex flex-col pt-14 sm:pt-20">
      <div className="pt-4 sm:pt-8">
        <h1 className="sr-only">{t.navPrivacy}</h1>
        <Heading title={t.privacyTitle} sub={t.privacySub} />
      </div>
      <ul className="mt-20 flex flex-col gap-14">
        {items.map(([icon, title, body]) => (
          <li key={title} className="grid grid-cols-[auto_1fr] gap-x-5">
            <span className="mt-0.5 text-accent">{icon}</span>
            <span className="flex flex-col gap-1.5">
              <span className="text-[21px] font-semibold tracking-[-0.01em]">{title}</span>
              <span className="max-w-[520px] text-[17px] leading-snug text-label-2">{body}</span>
            </span>
          </li>
        ))}
      </ul>

      <section aria-labelledby="policy" className="mt-28 border-t border-separator pt-14">
        <h2 id="policy" className="text-[28px] font-bold tracking-[-0.02em]">
          {t.policyTitle}
        </h2>
        <div className="mt-8 flex max-w-[620px] flex-col gap-8">
          {t.policy.map((part) => (
            <div key={part.h} className="flex flex-col gap-2 text-[15px] leading-relaxed text-label-2">
              <h3 className="text-[17px] font-semibold text-label">{part.h}</h3>
              {part.p.map((line) => (
                <p key={line}>{line}</p>
              ))}
              {part.list && (
                <ul className="flex list-disc flex-col gap-1 pl-5 marker:text-label-3">
                  {part.list.map((item) => (
                    <li key={item}>{item}</li>
                  ))}
                </ul>
              )}
              {part.after?.map((line) => (
                <p key={line}>{line}</p>
              ))}
            </div>
          ))}
        </div>
        <p className="mt-12 text-[13px] text-label-3">
          {fmt(t.policyUpdated, { date: POLICY_DATE })} · {t.policyContact}:{" "}
          <a href={`mailto:${POLICY_EMAIL}`} className="text-accent hover:underline">
            {POLICY_EMAIL}
          </a>
          {CONTROLLER && ` · ${t.policyController}: ${CONTROLLER}`}
        </p>
      </section>
    </div>
  );
}
