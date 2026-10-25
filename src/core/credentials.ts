// BDK API key resolution (DESIGN §5.2). Returns the key plus the name of its source; callers
// may show or log the source, never the key. Detection of an existing BDK login can be
// switched off so new-user setup can be validated without Felix's credentials leaking in.
import { readFile } from "node:fs/promises";
import { homedir } from "node:os";
import { join } from "node:path";
import { isRecord, readJson } from "./fsutil.ts";

export interface Credential {
  key: string;
  source: string;
}

async function readKeyFile(path: string): Promise<string | null> {
  try {
    return (await readFile(path, "utf8")).trim() || null;
  } catch {
    return null;
  }
}

/** A trimmed, non-empty string field of a parsed JSON object, else null. */
function stringField(v: unknown, field: string): string | null {
  const s = isRecord(v) ? v[field] : undefined;
  return typeof s === "string" && s.trim() ? s.trim() : null;
}

async function readCredentialsJson(path: string): Promise<string | null> {
  try {
    return stringField(await readJson(path, null), "apiKey");
  } catch {
    return null;
  }
}

export function detectionPaths(env: NodeJS.ProcessEnv, home: string = homedir()): { path: string; source: string }[] {
  const dir = env.AGENT_SERVE_CONFIG_DIR || join(home, ".config/agent-serve");
  return [{ path: join(dir, "credentials.json"), source: "detected:agent-serve" }];
}

export async function resolveCredential({ env = process.env, secretsFile, detect, userHome }: {
  env?: NodeJS.ProcessEnv;
  secretsFile: string;
  detect?: boolean;
  userHome?: string | undefined;
}): Promise<Credential | null> {
  if (env.CURSOR_API_KEY?.trim()) return { key: env.CURSOR_API_KEY.trim(), source: "env:CURSOR_API_KEY" };
  if (env.CURSOR_API_KEY_FILE) {
    const k = await readKeyFile(env.CURSOR_API_KEY_FILE);
    if (k) return { key: k, source: "env:CURSOR_API_KEY_FILE" };
  }
  if (env.CURSOR_SERVICE_ACCOUNT_KEY?.trim()) return { key: env.CURSOR_SERVICE_ACCOUNT_KEY.trim(), source: "env:CURSOR_SERVICE_ACCOUNT_KEY" };
  const saved = stringField(await readJson(secretsFile, {}), "bdkApiKey");
  if (saved) return { key: saved, source: "homebot:secrets" };
  const detectOn = detect ?? env.HOMEBOT_DETECT_CREDENTIALS !== "0";
  if (detectOn) {
    for (const { path, source } of detectionPaths(env, userHome)) {
      const k = await readCredentialsJson(path);
      if (k) return { key: k, source };
    }
  }
  return null;
}
