import { beforeAll, describe, expect, it } from "vitest";
import { parsePing } from "../src/ping";
import { call, env, rows, setClock } from "./helpers";

beforeAll(async () => {
  await env.RELEASES.put("releases/Homebot-0.1.0.zip", new Uint8Array(10));
});

const base = { v: 1, day: "2026-11-10", app: "0.1.0", build: "direct", os: "26", arch: "arm64", lang: "zh-Hans", cohort: "2026-11", age: "0-1d", use7d: "1-5", newWeek: true, newMonth: true, first: true };
const post = (body: unknown, cf?: Record<string, unknown>) =>
  call("/api/v1/ping", { method: "POST", headers: { "content-type": "application/json" }, body: typeof body === "string" ? body : JSON.stringify(body), cf });
const now = new Date("2026-11-10T12:00:00Z");

describe("ping validation", () => {
  it("accepts exactly the documented fields", () => {
    expect(parsePing(JSON.stringify(base), now)).not.toBeNull();
  });
  it.each([
    ["an extra field", { ...base, id: "abc" }],
    ["a missing field", (({ age, ...r }) => r)(base)],
    ["free text in a closed field", { ...base, lang: "en-GB; Felix's Mac" }],
    ["a future cohort", { ...base, cohort: "2027-01" }],
    ["a cohort before Homebot existed", { ...base, cohort: "2025-01" }],
    ["an unknown macOS", { ...base, os: "10" }],
    ["a string flag", { ...base, first: "true" }],
    ["a bad version", { ...base, app: "0.1.0-beta+hostname" }],
    ["an array", [base]],
    ["a day two days off", { ...base, day: "2026-11-08" }],
    ["a day that doesn't exist", { ...base, day: "2026-11-31" }],
  ])("rejects %s", (_, p) => {
    expect(parsePing(JSON.stringify(p), now)).toBeNull();
  });
});

describe("ping endpoint", () => {
  it("adds 1 to each marginal counter and stores nothing else", async () => {
    setClock(now);
    const r = await post(base, { country: "JP" });
    expect(r.status).toBe(204);
    const got = await rows<{ kind: string; dim: string; value: string; n: number }>("SELECT kind, dim, value, n FROM active_daily WHERE day = '2026-11-10' ORDER BY kind, dim, value");
    expect(got).toEqual([
      { kind: "day", dim: "all", value: "-", n: 1 },
      { kind: "day", dim: "app", value: "0.1.0", n: 1 },
      { kind: "day", dim: "arch", value: "arm64", n: 1 },
      { kind: "day", dim: "build", value: "direct", n: 1 },
      { kind: "day", dim: "country", value: "JP", n: 1 },
      { kind: "day", dim: "lang", value: "zh-Hans", n: 1 },
      { kind: "day", dim: "os", value: "26", n: 1 },
      { kind: "day", dim: "use7d", value: "1-5", n: 1 },
      { kind: "first", dim: "age", value: "0-1d", n: 1 },
      { kind: "first", dim: "cohort", value: "2026-11", n: 1 },
      { kind: "month", dim: "all", value: "-", n: 1 },
      { kind: "month", dim: "app", value: "0.1.0", n: 1 },
      { kind: "month", dim: "cohort", value: "2026-11", n: 1 },
      { kind: "month", dim: "country", value: "JP", n: 1 },
      { kind: "week", dim: "all", value: "-", n: 1 },
      { kind: "week", dim: "app", value: "0.1.0", n: 1 },
    ]);
    expect(await rows("SELECT * FROM active_version_os")).toEqual([{ day: "2026-11-10", app: "0.1.0", os: "26", n: 1 }]);
  });

  it("a repeat ping later in the week only counts the day", async () => {
    setClock("2026-11-11T08:00:00Z");
    await post({ ...base, day: "2026-11-11", newWeek: false, newMonth: false, first: false, age: "2-7d" });
    const kinds = await rows<{ kind: string; n: number }>("SELECT kind, SUM(n) AS n FROM active_daily WHERE day = '2026-11-11' AND dim = 'all' GROUP BY kind");
    expect(kinds).toEqual([{ kind: "day", n: 1 }]);
    expect(await rows("SELECT value FROM active_daily WHERE day = '2026-11-11' AND dim = 'country'")).toEqual([{ value: "ZZ" }]);
  });

  it("counts a ping on the app's day, so a ping sent just before midnight stays in its week and month", async () => {
    setClock("2026-12-01T00:00:02Z");
    expect((await post({ ...base, day: "2026-11-30", newWeek: false, newMonth: false, first: false })).status).toBe(204);
    expect(await rows("SELECT kind, n FROM active_daily WHERE day = '2026-11-30' AND dim = 'all'")).toEqual([{ kind: "day", n: 1 }]);
    expect(await rows("SELECT * FROM active_daily WHERE day = '2026-12-01'")).toEqual([]);
  });

  it("ignores versions that were never released", async () => {
    setClock("2026-11-13T08:00:00Z");
    expect((await post({ ...base, day: "2026-11-13", app: "12.345.678" })).status).toBe(204);
    expect(await rows("SELECT * FROM active_daily WHERE day = '2026-11-13'")).toEqual([]);
  });

  it("answers 204 to anything and writes nothing for bad input", async () => {
    setClock("2026-11-12T08:00:00Z");
    expect((await post("not json")).status).toBe(204);
    expect((await post({ ...base, lang: "xx" })).status).toBe(204);
    expect((await post("x".repeat(5000))).status).toBe(204);
    expect((await call("/api/v1/ping")).status).toBe(405);
    expect(await rows("SELECT * FROM active_daily WHERE day = '2026-11-12'")).toEqual([]);
  });
});
