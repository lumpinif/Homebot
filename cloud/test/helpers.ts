import { createExecutionContext, waitOnExecutionContext } from "cloudflare:test";
import { env as testEnv } from "cloudflare:workers";
import type { Deps, Env, Mail } from "../src/env";
import { route } from "../src/index";

export const env = testEnv as unknown as Env;
export const sent: Mail[] = [];
export let clock = new Date("2026-11-03T12:00:00Z");
export function setClock(d: string | Date) {
  clock = new Date(d);
}

/** Never sends: mails land in `sent`. */
export const deps: Deps = { now: () => clock, send: async (m) => void sent.push(m) };

export async function call(input: string, init: RequestInit & { cf?: Record<string, unknown> } = {}): Promise<Response> {
  const ctx = createExecutionContext();
  const res = await route(new Request(`https://homebot.fun${input}`, init), env, deps, ctx);
  await waitOnExecutionContext(ctx);
  return res;
}

export async function rows<T = Record<string, unknown>>(sql: string, ...binds: unknown[]): Promise<T[]> {
  return (await env.DB.prepare(sql).bind(...binds).all<T>()).results;
}

export function linkFrom(mail: Mail, path: string): string {
  const m = mail.text.match(new RegExp(`https://homebot\\.fun(${path}\\?token=[A-Za-z0-9_.-]+)`));
  if (!m) throw new Error(`no ${path} link in mail`);
  return m[1];
}
