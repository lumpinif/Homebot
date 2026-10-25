import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, stat, mkdir, writeFile, readdir } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { resolveHome, prepareHome, findGitRoot } from "../src/core/home.ts";
import { writeJson, readJson, writePrivateFile, TMP_SUFFIX } from "../src/core/fsutil.ts";

const tmp = () => mkdtemp(join(tmpdir(), "homebot-test-"));
const mode = async (p: string) =>(await stat(p)).mode & 0o777;

test("home dir and subdirs are created 0700", async () => {
  const root = join(await tmp(), "hb");
  const home = resolveHome({ env: { HOMEBOT_HOME: root } });
  await prepareHome(home);
  assert.equal(await mode(root), 0o700);
  assert.equal(await mode(home.paths.logs), 0o700);
  assert.equal(await mode(home.paths.shortcuts), 0o700);
});

test("existing world-readable home dir is tightened", async () => {
  const root = join(await tmp(), "hb");
  await mkdir(root, { mode: 0o755 });
  await prepareHome(resolveHome({ env: { HOMEBOT_HOME: root } }));
  assert.equal(await mode(root), 0o700);
});

test("refuses HOMEBOT_HOME inside a git work tree", async () => {
  const repo = await tmp();
  await mkdir(join(repo, ".git"));
  const env = { HOMEBOT_HOME: join(repo, "data") };
  assert.equal(findGitRoot(join(repo, "data")), repo);
  assert.throws(() => resolveHome({ env }), /inside a git work tree/);
  assert.doesNotThrow(() => resolveHome({ env: { ...env, HOMEBOT_ALLOW_HOME_IN_GIT: "1" } }));
});

test("private files are 0600 and JSON round-trips", async () => {
  const dir = await tmp();
  const f = join(dir, "sub", "secrets.json");
  await writeJson(f, { a: 1 });
  assert.equal(await mode(f), 0o600);
  assert.equal(await mode(join(dir, "sub")), 0o700);
  assert.deepEqual(await readJson(f, null), { a: 1 });
  assert.equal(await readJson(join(dir, "missing.json"), "fb"), "fb");
});

test("overwriting keeps 0600 and leaves no temp files", async () => {
  const dir = await tmp();
  const f = join(dir, "x.json");
  await writePrivateFile(f, "1");
  await writePrivateFile(f, "2");
  assert.equal(await mode(f), 0o600);
  assert.deepEqual(await readdir(dir), ["x.json"]);
});

test("startup sweep removes leftover temp files", async () => {
  const root = join(await tmp(), "hb");
  const home = resolveHome({ env: { HOMEBOT_HOME: root } });
  await prepareHome(home);
  await writeFile(join(root, `.secrets.json.abc${TMP_SUFFIX}`), "partial");
  await writeFile(join(home.paths.shortcuts, `.x.abc${TMP_SUFFIX}`), "partial");
  await prepareHome(home);
  assert.deepEqual((await readdir(root)).filter((n) => n.endsWith(TMP_SUFFIX)), []);
  assert.deepEqual(await readdir(home.paths.shortcuts), []);
});
