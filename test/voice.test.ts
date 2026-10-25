import { test, afterEach } from "node:test";
import assert from "node:assert/strict";
import net from "node:net";
import type http from "node:http";
import type { AddressInfo } from "node:net";
import { setTimeout as sleep } from "node:timers/promises";
import { createVoiceServer, type VoiceConfig } from "../src/server/voice.ts";
import type { AskRequest, AskResult } from "../src/core/ask.ts";
import type { TokenRecord, VerifyResult } from "../src/core/tokens.ts";
import { must } from "../test-helpers/must.ts";

let server: http.Server | undefined;
afterEach(async () => {
  server?.closeAllConnections();
  await new Promise<void>((r) => (server ? server.close(() => r()) : r()));
  server = undefined;
});

const RECORD: TokenRecord = { id: "aaaaaaaaaaaa", hash: "", bot: "chai", label: "test", state: "active", createdAt: 0 };
const config: VoiceConfig = { settings: { rateLimitPerMin: 100 }, bot: () => undefined };

type Verify = (token: unknown) => Promise<VerifyResult>;

async function start({ verify = async () => ({ ok: true, record: RECORD }), probeWait = false }: { verify?: Verify; probeWait?: boolean } = {}) {
  const asked: AskRequest[] = [];
  const logs: Record<string, unknown>[] = [];
  const ask = { ask: async (q: AskRequest): Promise<AskResult> => (asked.push(q), { text: `got:${q.text}`, outcome: "answered", timings: {} }) };
  const s = createVoiceServer({ ask, tokens: { verify }, config, log: (e) => logs.push(e), probeWait, probeUnitMs: 5 });
  server = s;
  await new Promise<void>((r) => s.listen(0, "127.0.0.1", r));
  // Listening on TCP, so address() is an AddressInfo.
  return { port: (s.address() as AddressInfo).port, asked, logs };
}

/** Send raw HTTP: headers, then body parts with pauses so they arrive as separate chunks. */
function rawRequest(port: number, bodyParts: Buffer[], { contentLength, destroyAfter = false }: { contentLength?: number; destroyAfter?: boolean } = {}): Promise<string> {
  return new Promise((resolve) => {
    const sock = net.connect(port, "127.0.0.1");
    let data = "";
    sock.on("data", (d) => (data += d));
    sock.on("close", () => resolve(data));
    sock.on("error", () => resolve(data));
    sock.on("connect", async () => {
      const len = contentLength ?? bodyParts.reduce((n, b) => n + b.length, 0);
      sock.write(`POST /v1/ask HTTP/1.1\r\nHost: x\r\nX-Homebot-Token: t\r\nContent-Type: application/json\r\nContent-Length: ${len}\r\nConnection: close\r\n\r\n`);
      for (const part of bodyParts) {
        sock.write(part);
        await sleep(30);
      }
      if (destroyAfter) sock.destroy();
    });
  });
}

const health = (port: number) => fetch(`http://127.0.0.1:${port}/v1/health`).then((r) => r.status);

test("B2: an interrupted upload neither crashes the gateway nor reaches the bot", async () => {
  const rejections: unknown[] = [];
  const onRej = (e: unknown) => rejections.push(e);
  process.on("unhandledRejection", onRej);
  try {
    const { port, asked } = await start();
    await rawRequest(port, [Buffer.from('{"text":"hal')], { contentLength: 500, destroyAfter: true });
    await sleep(50);
    assert.equal(await health(port), 200, "gateway still serving");
    assert.equal(asked.length, 0);
    assert.deepEqual(rejections, []);
  } finally {
    process.off("unhandledRejection", onRej);
  }
});

test("B2: disconnect during slow token activation -> AskService is never called", async () => {
  const { port, asked } = await start({
    verify: async () => {
      await sleep(150);
      return { ok: true, record: RECORD };
    },
  });
  await rawRequest(port, [Buffer.from('{"text":"hello"}')], { destroyAfter: true });
  await sleep(250);
  assert.equal(asked.length, 0);
  assert.equal(await health(port), 200);
});

test("B2: a failing token write returns 500 and the gateway survives", async () => {
  const { port, asked, logs } = await start({
    verify: async () => {
      throw new Error("EACCES: synthetic write failure /secret/path");
    },
  });
  const res = await fetch(`http://127.0.0.1:${port}/v1/ask`, { method: "POST", headers: { "X-Homebot-Token": "t" }, body: '{"text":"hi"}' });
  assert.equal(res.status, 500);
  assert.equal(await res.text(), "Homebot ran into an error. Please try again later.");
  assert.equal(asked.length, 0);
  assert.equal(await health(port), 200);
  assert.ok(!JSON.stringify(logs).includes("/secret/path"), "error details are not logged");
});

test("probe-wait: off by default; when on, cycles delays, speaks in the token's language, logs give-ups", async () => {
  {
    const { port } = await start();
    assert.equal((await fetch(`http://127.0.0.1:${port}/v1/probe-wait`, { headers: { "X-Homebot-Token": "t" } })).status, 404);
  }
  const first = must(server);
  first.closeAllConnections();
  await new Promise<void>((r) => first.close(() => r()));
  const zhRecord = { ...RECORD, siriLang: "zh-CN" };
  const { port, asked, logs } = await start({ probeWait: true, verify: async (t) => (t === "t" ? { ok: true, record: zhRecord } : { ok: false, reason: "invalid" }) });
  const get = (headers: Record<string, string>, signal?: AbortSignal) => fetch(`http://127.0.0.1:${port}/v1/probe-wait`, signal ? { headers, signal } : { headers });
  assert.equal((await get({ "X-Homebot-Token": "bad" })).status, 401);
  assert.equal(await (await get({ "X-Homebot-Token": "t" })).text(), "等了5秒，收到。");
  assert.equal(await (await get({ "X-Homebot-Token": "t" })).text(), "等了10秒，收到。");
  await assert.rejects(get({ "X-Homebot-Token": "t" }, AbortSignal.timeout(20))); // 15 s step (75 ms here): client gives up
  await sleep(100);
  assert.deepEqual(logs.filter((e) => e.event === "probe-end").map((e) => [e.s, e.delivered]), [[5, true], [10, true], [15, false]]);
  assert.equal(asked.length, 0, "the probe never talks to a bot");
});

test("TS review S1: a body that is not a JSON object is 400 before authentication", async () => {
  const verified: unknown[] = [];
  const { port, asked } = await start({ verify: async (t) => (verified.push(t), { ok: true, record: RECORD }) });
  const post = (body: string) => fetch(`http://127.0.0.1:${port}/v1/ask`, { method: "POST", headers: { "X-Homebot-Token": "t" }, body });
  for (const body of ["[]", '[{"text":"hi"}]', "null", '"hi"', "5", "true"]) {
    const res = await post(body);
    assert.equal(res.status, 400, body);
    assert.deepEqual(await res.json(), { error: "bad json" }, body);
  }
  assert.deepEqual(verified, [], "no token was checked, so none was activated or retired");
  assert.equal(asked.length, 0);
  const ok = await post('{"text":"hi"}');
  assert.equal(await ok.text(), "got:hi", "an object body still works");
  assert.equal(verified.length, 1);
});

test("S1: UTF-8 characters split across chunks arrive intact", async () => {
  const { port, asked } = await start();
  const body = Buffer.from(JSON.stringify({ text: "中文 😀 ok" }));
  const cut1 = body.indexOf(Buffer.from("中")) + 1; // inside 中 (3 bytes)
  const cut2 = body.indexOf(Buffer.from("😀")) + 2; // inside 😀 (4 bytes)
  const reply = await rawRequest(port, [body.subarray(0, cut1), body.subarray(cut1, cut2), body.subarray(cut2)]);
  assert.equal(must(asked[0]).text, "中文 😀 ok");
  assert.match(reply, /got:中文 😀 ok/);
});
