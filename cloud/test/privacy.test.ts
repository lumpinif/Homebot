import { describe, expect, it } from "vitest";
// Static guard: the Worker must never read the client IP or log requests.
const sources = import.meta.glob("../src/*.ts", { query: "?raw", import: "default", eager: true }) as Record<string, string>;
const schema = import.meta.glob("../migrations/*.sql", { query: "?raw", import: "default", eager: true }) as Record<string, string>;

describe("privacy guards", () => {
  it("has sources to check", () => expect(Object.keys(sources).length).toBeGreaterThan(5));
  it.each(Object.entries(sources))("%s reads no IP header and logs nothing", (_, code) => {
    const live = code.replace(/\/\/.*$/gm, "").replace(/\/\*[\s\S]*?\*\//g, "");
    expect(live).not.toMatch(/cf-connecting-ip|x-forwarded-for|x-real-ip|true-client-ip|clientIp/i);
    expect(live).not.toMatch(/console\./);
  });
  it("stores no IP, user agent or identifier column", () => {
    const sql = Object.values(schema).join("\n").replace(/--.*$/gm, "");
    expect(sql).not.toMatch(/\b(ip|ip_address|user_agent|ua|device_id|install_id)\b/i);
  });
});
