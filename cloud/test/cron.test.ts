import { describe, expect, it } from "vitest";
import { cleanup, kAnon, kAnonRows, snapshot } from "../src/cron";
import { env, rows } from "./helpers";

describe("cleanup", () => {
  it("deletes stale pending sign-ups and throttle rows, keeps confirmed ones", async () => {
    await env.DB.batch([
      env.DB.prepare("INSERT INTO subscribers (pid, email, lang, source, consent_version, created_at, confirmed_at) VALUES ('p1','old@example.com','en','app','v','2026-11-01T00:00:00Z',NULL)"),
      env.DB.prepare("INSERT INTO subscribers (pid, email, lang, source, consent_version, created_at, confirmed_at) VALUES ('p2','new@example.com','en','app','v','2026-11-07T00:00:00Z',NULL)"),
      env.DB.prepare("INSERT INTO subscribers (pid, email, lang, source, consent_version, created_at, confirmed_at) VALUES ('p3','kept@example.com','en','app','v','2026-10-01T00:00:00Z','2026-10-01T01:00:00Z')"),
      env.DB.prepare("INSERT INTO signup_throttle VALUES ('h1','2026-11-07T00:00:00Z','2026-11-07T00:00:00Z',1)"),
    ]);
    await cleanup(env, new Date("2026-11-09T00:00:00Z"));
    expect((await rows<{ email: string }>("SELECT email FROM subscribers ORDER BY email")).map((r) => r.email)).toEqual(["kept@example.com", "new@example.com"]);
    expect(await rows("SELECT * FROM signup_throttle")).toEqual([]);
  });
});

describe("monthly snapshot", () => {
  it("merges rare countries into other", () => {
    expect(kAnon([{ country: "US", n: 40 }, { country: "IS", n: 6 }, { country: "ZZ", n: 4 }, { country: "DE", n: 10 }])).toEqual({ US: 40, DE: 10, other: 10 });
  });

  it("leaves out an \"other\" that is itself rare", () => {
    expect(kAnon([{ country: "US", n: 40 }, { country: "IS", n: 1 }])).toEqual({ US: 40 });
  });

  it("merges rare values of every dimension, keeps totals", () => {
    expect(kAnonRows([
      { kind: "day", dim: "all", value: "-", n: 3 },
      { kind: "day", dim: "os", value: "26", n: 30 },
      { kind: "day", dim: "os", value: "15", n: 4 },
      { kind: "day", dim: "os", value: "16", n: 6 },
      { kind: "day", dim: "lang", value: "ko", n: 2 },
    ])).toEqual([
      { kind: "day", dim: "all", value: "-", n: 3 },
      { kind: "day", dim: "os", value: "26", n: 30 },
      { kind: "day", dim: "os", value: "other", n: 10 },
    ]);
  });

  it("writes last month's totals and a chained ledger line, once", async () => {
    await env.DB.batch([
      env.DB.prepare("INSERT INTO downloads_daily VALUES ('2026-11-02','0.1.0','install',30)"),
      env.DB.prepare("INSERT INTO downloads_country_daily VALUES ('2026-11-02','US',25)"),
      env.DB.prepare("INSERT INTO downloads_country_daily VALUES ('2026-11-02','IS',5)"),
      env.DB.prepare("INSERT INTO active_daily VALUES ('2026-11-02','day','all','-',7)"),
      env.DB.prepare("INSERT INTO active_daily VALUES ('2026-11-02','month','country','IS',1)"),
      env.DB.prepare("INSERT INTO downloads_daily VALUES ('2026-12-01','0.1.0','install',99)"),
    ]);
    expect(await snapshot(env, new Date("2026-12-01T04:00:00Z"))).toBe("stats/2026-11.json");
    const s = JSON.parse(await (await env.RELEASES.get("stats/2026-11.json"))!.text());
    expect(s.downloads).toEqual([{ version: "0.1.0", channel: "install", n: 30 }]);
    expect(s.downloadsByCountry).toEqual({ US: 25 });
    expect(s.activeByCountry).toEqual({});
    expect(s.activePerDay).toEqual([{ day: "2026-11-02", n: 7 }]);
    expect(s.subscribers.confirmed).toBe(1);
    const ledger = (await (await env.RELEASES.get("stats/ledger.txt"))!.text()).trim().split("\n");
    expect(ledger).toHaveLength(1);
    expect(ledger[0]).toMatch(/^2026-11 [0-9a-f]{64} [0-9a-f]{64}$/);
    expect(await snapshot(env, new Date("2026-12-01T04:05:00Z"))).toBeNull();
  });

  it("adds a missing ledger line for a file written before a failure", async () => {
    await env.RELEASES.put("stats/2026-12.json", '{"month":"2026-12"}');
    expect(await snapshot(env, new Date("2027-01-01T04:00:00Z"))).toBe("stats/2026-12.json");
    expect(await (await env.RELEASES.get("stats/2026-12.json"))!.text()).toBe('{"month":"2026-12"}');
    const ledger = (await (await env.RELEASES.get("stats/ledger.txt"))!.text()).trim().split("\n");
    expect(ledger.map((l) => l.split(" ")[0])).toEqual(["2026-11", "2026-12"]);
    expect(await snapshot(env, new Date("2027-01-01T04:05:00Z"))).toBeNull();
  });
});
