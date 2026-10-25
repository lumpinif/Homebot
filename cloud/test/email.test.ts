import { beforeEach, describe, expect, it } from "vitest";
import { normalizeEmail } from "../src/email";
import { call, env, linkFrom, rows, sent, setClock } from "./helpers";

const sub = (body: Record<string, unknown>) =>
  call("/api/v1/subscribe", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(body) });
const form = (path: string, fields: Record<string, string>) =>
  call(path, { method: "POST", headers: { "content-type": "application/x-www-form-urlencoded" }, body: new URLSearchParams(fields).toString() });
const tokenOf = (path: string) => new URL(`https://x${path}`).searchParams.get("token")!;
type Sub = { email: string; lang: string; created_at: string; confirmed_at: string | null };
const subscriber = async (email: string) => (await rows<Sub>("SELECT * FROM subscribers WHERE email = ?", email))[0];

beforeEach(() => {
  sent.length = 0;
});

describe("normalizeEmail", () => {
  it("lower-cases and trims", () => expect(normalizeEmail("  Ann@Example.COM ")).toBe("ann@example.com"));
  it.each(["", "a@b", "no-at.example.com", "a b@example.com", "<a@example.com>", "a..b@example.com", "a@example..com", 42, "x".repeat(250) + "@e.com"])(
    "rejects %s", (e) => expect(normalizeEmail(e)).toBeNull());
});

describe("sign-up, confirm, manage, unsubscribe", () => {
  it("runs the whole double opt-in", async () => {
    setClock("2026-11-01T10:00:00Z");
    const r = await sub({ email: "Ann@Example.com", lang: "de", source: "app" });
    expect(r.status).toBe(202);
    expect(await r.json()).toEqual({ status: "check-inbox" });
    expect(sent).toHaveLength(1);
    expect(sent[0].to).toBe("ann@example.com");
    expect(sent[0].text).toContain("Homebot product updates");
    expect(sent[0].text).not.toContain("offers");
    expect((await subscriber("ann@example.com")).confirmed_at).toBeNull();

    // Opening the link (a mail scanner would) only shows a button.
    const link = linkFrom(sent[0], "/confirm");
    const shown = await call(link);
    expect(shown.status).toBe(200);
    expect(await shown.text()).toContain('method="post"');
    expect((await subscriber("ann@example.com")).confirmed_at).toBeNull();

    const done = await form("/confirm", { token: tokenOf(link) });
    expect(await done.text()).toContain("You're subscribed");
    expect((await subscriber("ann@example.com")).confirmed_at).toBe("2026-11-01T10:00:00.000Z");
  });

  it("answers an existing address the same way and never changes it from the form", async () => {
    setClock("2026-11-01T11:00:00Z");
    const r = await sub({ email: "ann@example.com", promos: true });
    expect(r.status).toBe(202);
    expect(await r.json()).toEqual({ status: "check-inbox" });
    expect(sent).toHaveLength(1);
    expect(sent[0].subject).toContain("already");
    expect(sent[0].headers?.["List-Unsubscribe-Post"]).toBe("List-Unsubscribe=One-Click");
    expect((await subscriber("ann@example.com")).lang).toBe("de");
  });

  it("manage shows the address and the list; its button unsubscribes", async () => {
    setClock("2026-11-01T12:00:00Z");
    await sub({ email: "ann@example.com" }); // throttled? 1 h after the last mail, 3rd of the day
    const mail = sent[0] ?? null;
    expect(mail).not.toBeNull();
    const manage = linkFrom(mail!, "/manage");
    const t = tokenOf(manage);
    const shown = await (await call(manage)).text();
    expect(shown).toContain("ann@example.com");
    expect(shown).toContain("product updates");
    expect(shown).not.toMatch(/offers|checkbox/i);
    expect(shown).toContain(`action="/unsubscribe?token=${t}"`);
    expect((await form("/manage", { token: t })).status).toBe(405);
    expect(await subscriber("ann@example.com")).toBeDefined();
    expect(await (await call(`/unsubscribe?token=${t}`, { method: "POST" })).text()).toContain("You're unsubscribed");
    expect(await subscriber("ann@example.com")).toBeUndefined();
  });

  it("unsubscribe: GET asks, POST (also one-click) deletes, then the link says it's done", async () => {
    setClock("2026-11-02T10:00:00Z");
    await sub({ email: "bob@example.com" });
    await form("/confirm", { token: tokenOf(linkFrom(sent[0], "/confirm")) });
    setClock("2026-11-02T10:30:00Z");
    await sub({ email: "bob@example.com" });
    const unsub = sent[1].headers!["List-Unsubscribe"].slice(1, -1).replace("https://homebot.fun", "");
    expect(await (await call(unsub)).text()).toContain("Unsubscribe from Homebot emails?");
    expect(await subscriber("bob@example.com")).toBeDefined();
    const one = await call(unsub, { method: "POST", headers: { "content-type": "application/x-www-form-urlencoded" }, body: "List-Unsubscribe=One-Click" });
    expect(one.status).toBe(200);
    expect(await subscriber("bob@example.com")).toBeUndefined();
    expect(await (await call(unsub, { method: "POST" })).text()).toContain("You're unsubscribed");
  });

  it("rejects tampered and malformed tokens", async () => {
    setClock("2026-11-03T10:00:00Z");
    await sub({ email: "cat@example.com" });
    const link = linkFrom(sent[0], "/confirm");
    const t = tokenOf(link);
    const bad = t.slice(0, -2) + (t.endsWith("AA") ? "BB" : "AA");
    expect((await form("/confirm", { token: bad })).status).toBe(400);
    expect((await call("/manage?token=nope")).status).toBe(400);
    expect((await call("/unsubscribe?token=")).status).toBe(400);
    // A confirm token is not a manage token.
    expect((await call(`/manage?token=${t}`)).status).toBe(400);
    expect((await subscriber("cat@example.com")).confirmed_at).toBeNull();
  });

  it("an old confirm link can't confirm what a later sign-up changed", async () => {
    setClock("2026-11-08T10:00:00Z");
    await sub({ email: "gus@example.com" });
    const old = linkFrom(sent[0], "/confirm");
    setClock("2026-11-08T10:30:00Z");
    await sub({ email: "gus@example.com", lang: "fr" });
    expect((await form("/confirm", { token: tokenOf(old) })).status).toBe(400);
    expect((await subscriber("gus@example.com")).confirmed_at).toBeNull();
  });

  it("an expired confirm link never hands out a manage link, even after confirming", async () => {
    setClock("2026-11-09T10:00:00Z");
    await sub({ email: "hal@example.com" });
    const link = linkFrom(sent[0], "/confirm");
    expect(await (await form("/confirm", { token: tokenOf(link) })).text()).toContain("/manage?token=");
    setClock("2026-11-30T10:00:00Z");
    const again = await form("/confirm", { token: tokenOf(link) });
    expect(again.status).toBe(400);
    expect(await again.text()).not.toContain("/manage?token=");
  });

  it("confirm links expire after 48 hours", async () => {
    setClock("2026-11-04T10:00:00Z");
    await sub({ email: "dan@example.com" });
    const link = linkFrom(sent[0], "/confirm");
    setClock("2026-11-06T10:00:01Z");
    expect((await call(link)).status).toBe(400);
    expect((await form("/confirm", { token: tokenOf(link) })).status).toBe(400);
  });
});

describe("abuse limits", () => {
  it("one mail per address per 10 minutes, three a day, and a throttled retry keeps the pending link", async () => {
    setClock("2026-11-05T10:00:00Z");
    await sub({ email: "eve@example.com" });
    const first = linkFrom(sent[0], "/confirm");
    setClock("2026-11-05T10:05:00Z");
    await sub({ email: "eve@example.com", lang: "ja" });
    expect(sent).toHaveLength(1);
    expect((await subscriber("eve@example.com")).lang).toBe("en");
    expect((await call(first)).status).toBe(200);
    setClock("2026-11-05T10:20:00Z");
    await sub({ email: "eve@example.com" });
    setClock("2026-11-05T10:40:00Z");
    await sub({ email: "eve@example.com" });
    setClock("2026-11-05T11:00:00Z");
    await sub({ email: "eve@example.com" });
    expect(sent).toHaveLength(3);
    // The newest link replaced the older ones.
    expect((await call(first)).status).toBe(400);
    setClock("2026-11-06T10:01:00Z");
    await sub({ email: "eve@example.com" });
    expect(sent).toHaveLength(4);
  });

  it("parallel sign-ups for one address still send one mail", async () => {
    setClock("2026-11-10T10:00:00Z");
    const all = await Promise.all(Array.from({ length: 8 }, () => sub({ email: "ivy@example.com" })));
    expect(all.every((r) => r.status === 202)).toBe(true);
    expect(sent).toHaveLength(1);
    expect(await rows("SELECT sends FROM signup_throttle WHERE sends > 3")).toEqual([]);
  });

  it("a big body is refused without being read whole", async () => {
    let pulled = 0;
    const body = new ReadableStream<Uint8Array>({
      pull(c) {
        pulled += 1;
        if (pulled > 1000) c.close();
        else c.enqueue(new Uint8Array(1024));
      },
    });
    const r = await call("/api/v1/subscribe", { method: "POST", body, duplex: "half" } as RequestInit);
    expect(r.status).toBe(400);
    expect(pulled).toBeLessThan(10);
  });

  it("stops all sign-up mail at the daily cap", async () => {
    setClock("2026-11-07T00:00:00Z");
    await env.DB.prepare("INSERT INTO mail_daily (day, n) VALUES ('2026-11-07', 500)").run();
    const r = await sub({ email: "fay@example.com" });
    expect(r.status).toBe(202);
    expect(sent).toHaveLength(0);
    expect(await subscriber("fay@example.com")).toBeUndefined();
  });

  it("validates input", async () => {
    expect((await sub({ email: "bad" })).status).toBe(400);
    expect((await sub({ updates: true })).status).toBe(400);
    expect((await call("/api/v1/subscribe", { method: "POST", body: "{" })).status).toBe(400);
    expect((await call("/api/v1/subscribe")).status).toBe(405);
  });

  it("keeps no plain address in the throttle table", async () => {
    const t = await rows<{ addr_hash: string }>("SELECT addr_hash FROM signup_throttle");
    expect(t.length).toBeGreaterThan(0);
    for (const r of t) expect(r.addr_hash).not.toContain("@");
  });
});
