// Private-file helpers. Every file we write may hold a secret, so it is created 0600
// from the first byte (temp file in the same dir, then rename) and never widened later.
import { mkdir, writeFile, readFile, rename, readdir, rm, chmod, stat, open } from "node:fs/promises";
import { setTimeout as sleep } from "node:timers/promises";
import { randomBytes } from "node:crypto";
import { dirname, join, basename } from "node:path";

export const TMP_SUFFIX = ".homebot-tmp";

/** The `code` of a Node system error (ENOENT, EEXIST, ...), if `e` is one. */
export function errnoCode(e: unknown): string | undefined {
  const code = e instanceof Error && "code" in e ? e.code : undefined;
  return typeof code === "string" ? code : undefined;
}

/** A parsed-JSON object (not null, not an array): the shape every file Homebot owns has. */
export function isRecord(v: unknown): v is Record<string, unknown> {
  return typeof v === "object" && v !== null && !Array.isArray(v);
}

/** Create a directory (and parents) with mode 0700; tighten it if it already exists. */
export async function ensurePrivateDir(dir: string): Promise<void> {
  await mkdir(dir, { recursive: true, mode: 0o700 });
  const s = await stat(dir);
  if ((s.mode & 0o077) !== 0) await chmod(dir, 0o700);
}

/** Atomically write `data` to `file` with mode 0600. */
export async function writePrivateFile(file: string, data: string | Uint8Array): Promise<void> {
  const dir = dirname(file);
  await ensurePrivateDir(dir);
  const tmp = join(dir, `.${basename(file)}.${randomBytes(6).toString("hex")}${TMP_SUFFIX}`);
  try {
    await writeFile(tmp, data, { mode: 0o600, flag: "wx" });
    await rename(tmp, file);
  } catch (e) {
    await rm(tmp, { force: true });
    throw e;
  }
}

export async function writeJson(file: string, value: unknown): Promise<void> {
  await writePrivateFile(file, JSON.stringify(value, null, 2) + "\n");
}

/**
 * Read JSON; returns `fallback` if the file does not exist. Parse errors are replaced by a
 * fixed message: Node's SyntaxError can quote file content, and these files hold secrets.
 * The content is `unknown`: callers validate the shape they need.
 */
export async function readJson<T>(file: string, fallback: T): Promise<unknown> {
  let raw: string;
  try {
    raw = await readFile(file, "utf8");
  } catch (e) {
    const code = errnoCode(e);
    if (code === "ENOENT") return fallback;
    throw new Error(`cannot read ${basename(file)} (${code ?? "error"})`);
  }
  try {
    return JSON.parse(raw) as unknown;
  } catch {
    throw new Error(`${file} is not valid JSON`);
  }
}

/**
 * Cross-process mutual exclusion via an O_EXCL lock file next to `file`. A lock older than
 * `staleMs` (crashed holder) is broken. Returns fn's result.
 */
export async function withFileLock<T>(file: string, fn: () => Promise<T>, { timeoutMs = 3000, staleMs = 10_000 }: { timeoutMs?: number; staleMs?: number } = {}): Promise<T> {
  const lock = `${file}.lock`;
  const start = Date.now();
  for (;;) {
    try {
      await (await open(lock, "wx", 0o600)).close();
      break;
    } catch (e) {
      if (errnoCode(e) !== "EEXIST") throw e;
      const s = await stat(lock).catch(() => null);
      if (s && Date.now() - s.mtimeMs > staleMs) {
        await rm(lock, { force: true });
        continue;
      }
      if (Date.now() - start > timeoutMs) throw new Error(`timed out waiting for ${basename(lock)}`);
      await sleep(15);
    }
  }
  try {
    return await fn();
  } finally {
    await rm(lock, { force: true });
  }
}

/** Delete leftover temp files from interrupted writes (called at startup). Returns count. */
export async function sweepTempFiles(dir: string): Promise<number> {
  let names: string[];
  try {
    names = await readdir(dir);
  } catch {
    return 0;
  }
  let n = 0;
  for (const name of names) {
    if (name.endsWith(TMP_SUFFIX)) {
      await rm(join(dir, name), { force: true });
      n++;
    }
  }
  return n;
}
