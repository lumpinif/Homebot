import { ChevronRight, Globe, HomeIcon, Smartphone, Speaker } from "lucide-react";
import { Alert, AlertContent, AlertDescription, AlertIcon } from "@/components/motion/alert";
import { Button } from "@/components/motion/button/base";
import { useLangName, useSetup } from "../setup";
import { Label, Note, StepHeader } from "../pieces";
import { Picker } from "../fluid";

export function LanguageStep({ onDone }: { onDone: () => void }) {
  const { state, T, saveSettings } = useSetup();
  const langName = useLangName();
  if (!state) return null;

  const put = (patch: { siriLang?: string; phoneLang?: string }) => saveSettings(patch, { done: T.saved });

  return (
    <div className="flex flex-col gap-8">
      <StepHeader icon={Globe} tint="bg-gradient-to-b from-violet-400 to-indigo-600" title={T.languageTitle} />

      <div className="flex flex-col gap-2">
        <Label id="siri-lang-label">
          <span className="inline-flex items-center gap-1.5">
            <Speaker className="size-3.5" />
            {T.siriLang}
          </span>
        </Label>
        <Picker
          label={T.siriLang}
          labelId="siri-lang-label"
          value={state.settings.siriLang}
          onChange={(v) => void put({ siriLang: v })}
          options={state.options.siriLangs.map((l) => ({ value: l.code, label: langName(l.code) }))}
        />
        {/* Where to look it up, as a path rather than a sentence. */}
        <div className="flex flex-wrap items-center gap-1 px-1 text-[12px] text-muted-foreground" aria-label={T.siriWhere.join(" › ")}>
          <HomeIcon className="size-3.5 text-orange-500" />
          {T.siriWhere.map((part, i) => (
            <span key={part} className="inline-flex items-center gap-1">
              {i > 0 ? <ChevronRight className="size-3 opacity-50" /> : null}
              <span className="rounded-md bg-muted px-1.5 py-0.5">{part}</span>
            </span>
          ))}
        </div>
      </div>

      <div className="flex flex-col gap-2">
        <Label id="phone-lang-label">
          <span className="inline-flex items-center gap-1.5">
            <Smartphone className="size-3.5" />
            {T.phoneLang}
          </span>
        </Label>
        <Picker
          label={T.phoneLang}
          labelId="phone-lang-label"
          value={state.settings.phoneLang}
          onChange={(v) => void put({ phoneLang: v })}
          options={state.options.phoneLangs.map((l) => ({ value: l.code, label: l.label }))}
        />
        <Note>{T.phoneNote}</Note>
      </div>

      {/* Installed Shortcuts keep their language (DESIGN §7.3). */}
      <Alert variant="warning" open={state.tokens.some((t) => t.languageDiffers && t.state !== "retired")} className="rounded-2xl">
        <AlertIcon />
        <AlertContent>
          <AlertDescription>{T.langApplies}</AlertDescription>
        </AlertContent>
      </Alert>

      <div className="flex justify-end">
        <Button onClick={onDone} className="min-w-28">
          {T.next}
        </Button>
      </div>
    </div>
  );
}
