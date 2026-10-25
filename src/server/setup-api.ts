// Response shapes of the setup page API (src/server/setup.ts). Types only, shared by the server,
// the setup page (web/src/api.ts) and the tests; nothing here exists at runtime.

export interface Option {
  code: string;
  label: string;
}

export interface CredentialView {
  source: string;
  /** env: overrides everything; saved: on this page; detected: another login on this Mac. */
  kind: "env" | "saved" | "detected";
  /** Only "ok" after Grok Bot accepted the key; never claimed before a real use. */
  access: "unchecked" | "ok" | "rejected";
}

export interface BotView {
  key: string;
  name: string;
  sessionId: string;
  strictEcho: boolean;
  synced: boolean;
}

export interface TokenView {
  id: string;
  bot: string;
  state: "pending" | "active" | "retired";
  label: string;
  siriLang: string;
  kind: "ask" | "probe" | "lab";
  createdAt: number;
  activatedAt: number | null;
  replaces: string | null;
  hasFile: boolean;
  languageDiffers: boolean;
}

/** GET /api/state, and every call that changes it. */
export interface SetupState {
  settings: { uiLang: string; siriLang: string; phoneLang: string };
  options: { uiLangs: Option[]; siriLangs: Option[]; phoneLangs: Option[] };
  credential: CredentialView | null;
  bots: BotView[];
  tokens: TokenView[];
  /** consent: the user turned on “Sign with Apple” (settings.appleSigning). */
  signing: { consent: boolean };
  probe: { enabled: boolean };
  gatewayUrl: string;
}

export interface PhraseProblemView {
  code: string;
  message: string;
  /** Refused, or advice only. */
  blocking: boolean;
}

/** POST /api/shortcuts/preview */
export interface ShortcutPreview {
  kind: "ask" | "probe";
  name: string;
  prompt: string | null;
  siriLang: string;
  /** What the user says, in the Siri language: "Hey Siri, <name>". */
  say: string;
  alternatives: string[];
  /** Problems with the phrase; building is refused while one is blocking. */
  problems: PhraseProblemView[];
  steps: string[];
}

/** POST /api/shortcuts */
export interface ShortcutBuild {
  tokenId: string;
  name: string;
  signed: boolean;
  fileName: string;
  steps: string[];
  state: SetupState;
}

/** POST /api/shortcuts/<tokenId>/link */
export interface DownloadLink {
  url: string;
  expiresAt: number;
  /** QR modules, one string of "0"/"1" per row. */
  qr: string[];
}

/** Any non-2xx response. */
export interface ApiErrorBody {
  error: { code: string; message: string };
}
