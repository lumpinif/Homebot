// Resolves HOMEBOT_HOME (default ~/.homebot) and refuses locations inside a git work tree, so
// secrets don't show up in `git status` (unless the user sets HOMEBOT_ALLOW_HOME_IN_GIT=1).
import { homedir } from "node:os";
import { join, resolve, dirname } from "node:path";
import { existsSync } from "node:fs";
import { ensurePrivateDir, sweepTempFiles } from "./fsutil.ts";

export interface Home {
  root: string;
  paths: { config: string; secrets: string; state: string; tokens: string; logs: string; shortcuts: string; lab: string };
}

/** The git work-tree root containing `dir`, if any. */
export function findGitRoot(dir: string): string | null {
  let cur = resolve(dir);
  for (;;) {
    if (existsSync(join(cur, ".git"))) return cur;
    const up = dirname(cur);
    if (up === cur) return null;
    cur = up;
  }
}

export function resolveHome({ env = process.env, allowInGit = false }: { env?: NodeJS.ProcessEnv; allowInGit?: boolean } = {}): Home {
  const root = resolve(env.HOMEBOT_HOME || join(homedir(), ".homebot"));
  const gitRoot = findGitRoot(root);
  if (gitRoot && !allowInGit && env.HOMEBOT_ALLOW_HOME_IN_GIT !== "1") {
    throw new Error(
      `HOMEBOT_HOME (${root}) is inside a git work tree (${gitRoot}). ` +
        "Homebot stores secrets there; choose a directory outside any repository.",
    );
  }
  return {
    root,
    paths: {
      config: join(root, "config.json"),
      secrets: join(root, "secrets.json"),
      state: join(root, "state.json"),
      tokens: join(root, "tokens.json"),
      logs: join(root, "logs"),
      shortcuts: join(root, "shortcuts"),
      lab: join(root, "lab.json"),
    },
  };
}

/** Create the private directory layout and clean up after interrupted writes. */
export async function prepareHome(home: Home): Promise<void> {
  await ensurePrivateDir(home.root);
  await ensurePrivateDir(home.paths.logs);
  await ensurePrivateDir(home.paths.shortcuts);
  await sweepTempFiles(home.root);
  await sweepTempFiles(home.paths.shortcuts);
}
