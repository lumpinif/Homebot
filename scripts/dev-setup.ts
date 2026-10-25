// Offline demo of the setup page: Homebot runs against an in-process FAKE Grok Bot API, with a
// throwaway HOMEBOT_HOME, so nothing touches real accounts, bots or ~/.homebot.
//   node scripts/dev-setup.ts         -> setup page on http://127.0.0.1:18788/
// The fake accepts only the dummy key printed below; bot "homebot" (session 14752726) exists and
// auto-replies. Any other name typed into "add by name" is created empty, like a typo would be.
// Signing is faked: nothing is sent to Apple.
// Pass --probe-wait to try the wait-test option.
import { copyFile, mkdtemp } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { startFakeBdk, FAKE_KEY } from "../test-helpers/fake-bdk.ts";
import { run } from "../src/cli.ts";

const fake = await startFakeBdk();
fake.addNamed("homebot", "14752726");
fake.add("14752726", { kind: "send-message", text: "(fake history)" });
fake.autoReply("14752726", { text: "This is the fake bot answering." });
const dir = await mkdtemp(join(tmpdir(), "homebot-demo-"));
const code = await run(["start", ...process.argv.slice(2).filter((a) => a === "--probe-wait")], {
  env: {
    HOMEBOT_HOME: join(dir, "home"),
    HOMEBOT_BDK_BASE_URL: fake.baseUrl,
    HOMEBOT_DETECT_CREDENTIALS: "0",
    HOMEBOT_PORT: process.env.HOMEBOT_PORT ?? "18787",
    HOMEBOT_SETUP_PORT: process.env.HOMEBOT_SETUP_PORT ?? "18788",
    HOMEBOT_BIND: "127.0.0.1",
  },
  userHome: dir,
  reveal: async (f) => console.log(`[demo] would reveal in Finder: ${f}`),
  // Never Apple's signing service in the demo: "Sign with Apple" copies the file unsigned.
  signer: async ({ input, output }) => {
    console.log("[demo] would send the Shortcut to Apple to sign it");
    await copyFile(input, output);
  },
});
if (code !== 0) process.exit(code);
console.log(`[demo] fake Grok Bot API key (dummy, not a secret): ${FAKE_KEY}`);
console.log('[demo] fake bot: name "homebot", session id 14752726');
