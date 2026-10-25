// Build the setup page (web/, React + beUI) into src/setup-ui, where it is committed and served:
// users run Homebot without installing anything (DECISIONS item 16). Needs web's dev
// dependencies (npm --prefix web install).
//   node scripts/build-ui.ts           -> rebuild src/setup-ui
//   node scripts/build-ui.ts --check   -> exit 1 if the committed build differs from a fresh one
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { mkdtemp, readFile, readdir, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, dirname, relative } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");
const WEB = join(ROOT, "web");
const UI = join(ROOT, "src", "setup-ui");

/** Run Vite's production build into `outDir`. */
async function viteBuild(outDir: string): Promise<void> {
  const vite = join(WEB, "node_modules", "vite", "bin", "vite.js");
  await promisify(execFile)(process.execPath, [vite, "build", "--logLevel", "warn"], { cwd: WEB, env: { ...process.env, HOMEBOT_UI_OUT: outDir } });
}

/** Every file under `dir`, keyed by its path relative to `dir`. */
async function files(dir: string): Promise<Map<string, string>> {
  const out = new Map<string, string>();
  for (const e of await readdir(dir, { recursive: true, withFileTypes: true })) {
    if (!e.isFile()) continue;
    const full = join(e.parentPath, e.name);
    // Base64 so binary files (the Grok Bot icon) compare byte for byte.
    out.set(relative(dir, full), (await readFile(full)).toString("base64"));
  }
  return out;
}

/** Paths that differ between the committed build and a fresh one (missing or extra included). */
export async function staleUiFiles(): Promise<string[]> {
  const out = await mkdtemp(join(tmpdir(), "homebot-ui-"));
  try {
    await viteBuild(out);
    const fresh = await files(out);
    const committed = await files(UI).catch(() => new Map<string, string>());
    const names = new Set([...fresh.keys(), ...committed.keys()]);
    return [...names].filter((n) => fresh.get(n) !== committed.get(n)).sort();
  } finally {
    await rm(out, { recursive: true, force: true });
  }
}

if (import.meta.main) {
  if (process.argv.includes("--check")) {
    const stale = await staleUiFiles();
    if (stale.length) {
      console.error(`Stale setup page build: ${stale.join(", ")}. Run: npm run build:ui`);
      process.exitCode = 1;
    } else {
      console.log("Setup page build is up to date.");
    }
  } else {
    await viteBuild(UI);
    console.log("Built the setup page into src/setup-ui/");
  }
}
