import { beforeAll, describe, expect, it } from "vitest";
import { call, env, rows, setClock } from "./helpers";

const ZIP = new Uint8Array(1000).map((_, i) => i % 251);

beforeAll(async () => {
  await env.RELEASES.put("releases/Homebot-0.1.0.zip", ZIP);
  await env.RELEASES.put("releases/latest.json", JSON.stringify({ version: "0.1.0", sha256: "ab".repeat(32) }));
});

const count = (day: string) => rows<{ version: string; channel: string; n: number }>("SELECT version, channel, n FROM downloads_daily WHERE day = ? ORDER BY channel", day);

describe("downloads", () => {
  it("latest redirects to the versioned file and keeps the channel", async () => {
    const r = await call("/download/latest?from=install", { redirect: "manual" });
    expect(r.status).toBe(302);
    expect(r.headers.get("location")).toBe("https://homebot.fun/download/Homebot-0.1.0.zip?from=install");
  });

  it("counts a download once per day, version, channel and country, and serves the file", async () => {
    setClock("2026-11-01T10:00:00Z");
    const r = await call("/download/Homebot-0.1.0.zip?from=install", { cf: { country: "DE" } });
    expect(r.status).toBe(200);
    expect(new Uint8Array(await r.arrayBuffer())).toEqual(ZIP);
    expect(r.headers.get("content-disposition")).toContain("Homebot-0.1.0.zip");
    await call("/download/Homebot-0.1.0.zip?from=install", { cf: { country: "DE" } });
    await call("/download/Homebot-0.1.0.zip?from=evil<script>");
    await call("/download/Homebot-0.1.0.zip");
    expect(await count("2026-11-01")).toEqual([
      { version: "0.1.0", channel: "direct", n: 1 },
      { version: "0.1.0", channel: "install", n: 2 },
      { version: "0.1.0", channel: "other", n: 1 },
    ]);
    expect(await rows("SELECT country, n FROM downloads_country_daily WHERE day = '2026-11-01' ORDER BY country")).toEqual([
      { country: "DE", n: 2 },
      { country: "ZZ", n: 2 },
    ]);
  });

  it("serves ranges; a resume isn't counted, a range from byte 0 is", async () => {
    setClock("2026-11-02T10:00:00Z");
    const r = await call("/download/Homebot-0.1.0.zip", { headers: { range: "bytes=100-199" } });
    expect(r.status).toBe(206);
    expect(r.headers.get("content-range")).toBe("bytes 100-199/1000");
    expect(new Uint8Array(await r.arrayBuffer())).toEqual(ZIP.slice(100, 200));
    expect(await count("2026-11-02")).toEqual([]);
    await call("/download/Homebot-0.1.0.zip", { headers: { range: "bytes=0-" } }).then((x) => x.arrayBuffer());
    expect(await count("2026-11-02")).toEqual([{ version: "0.1.0", channel: "direct", n: 1 }]);
  });

  it("a probe of the first bytes isn't a download; bad ranges never break the response", async () => {
    setClock("2026-11-05T10:00:00Z");
    expect((await call("/download/Homebot-0.1.0.zip", { headers: { range: "bytes=0-0" } })).status).toBe(206);
    const backwards = await call("/download/Homebot-0.1.0.zip?from=home", { headers: { range: "bytes=100-0" } });
    expect(backwards.status).toBe(200);
    expect((await backwards.arrayBuffer()).byteLength).toBe(1000);
    const past = await call("/download/Homebot-0.1.0.zip", { headers: { range: "bytes=5000-" } });
    expect(past.status).toBe(416);
    expect(past.headers.get("content-range")).toBe("bytes */1000");
    const tail = await call("/download/Homebot-0.1.0.zip", { headers: { range: "bytes=990-2000" } });
    expect(tail.status).toBe(206);
    expect(tail.headers.get("content-range")).toBe("bytes 990-999/1000");
    expect(await count("2026-11-05")).toEqual([]);
  });

  it("HEAD and unknown files don't count", async () => {
    setClock("2026-11-03T10:00:00Z");
    expect((await call("/download/Homebot-0.1.0.zip", { method: "HEAD" })).status).toBe(200);
    expect((await call("/download/Homebot-9.9.9.zip")).status).toBe(404);
    expect((await call("/download/../secrets")).status).toBe(404);
    expect((await call("/download/Homebot-0.1.0.zip", { method: "POST" })).status).toBe(405);
    expect(await count("2026-11-03")).toEqual([]);
  });
});

describe("update check", () => {
  it("answers the newest version and only counts the check", async () => {
    setClock("2026-11-04T10:00:00Z");
    const r = await call("/api/v1/latest?anything=ignored");
    expect(await r.json()).toEqual({ version: "0.1.0", url: "https://homebot.fun/download/Homebot-0.1.0.zip?from=app", sha256: "ab".repeat(32) });
    await call("/api/v1/latest");
    expect(await rows("SELECT * FROM update_checks_daily")).toEqual([{ day: "2026-11-04", n: 2 }]);
  });
});

describe("site addresses", () => {
  it("/privacy and /install open the site's page of that name", async () => {
    for (const p of ["privacy", "install"]) {
      const r = await call(`/${p}`, { redirect: "manual" });
      expect(r.status).toBe(301);
      expect(r.headers.get("location")).toBe(`/#${p}`);
    }
  });
});
