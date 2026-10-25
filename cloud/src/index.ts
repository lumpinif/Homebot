import { handleDownload, handleLatest } from "./download";
import { handleConfirm, handleManage, handleSubscribe, handleUnsubscribe } from "./email";
import { cleanup, snapshot } from "./cron";
import { type Deps, type Env, liveDeps } from "./env";
import { handlePing } from "./ping";
import { empty } from "./util";

// Nothing here reads CF-Connecting-IP, X-Forwarded-For or logs a request: see the privacy notes in DEPLOY.md.

export async function route(request: Request, env: Env, deps: Deps, ctx: ExecutionContext): Promise<Response> {
  const url = new URL(request.url);
  const p = url.pathname;
  if (p.startsWith("/download/")) return handleDownload(request, env, deps, ctx, url);
  if (p === "/api/v1/latest") return handleLatest(request, env, deps, ctx);
  if (p === "/api/v1/ping") return handlePing(request, env, deps, ctx);
  if (p === "/api/v1/subscribe") return handleSubscribe(request, env, deps, ctx);
  if (p === "/confirm") return handleConfirm(request, env, deps, url);
  if (p === "/unsubscribe") return handleUnsubscribe(request, env, url);
  if (p === "/manage") return handleManage(request, env, url);
  // The site picks its page from the #hash; these are the plain addresses people and emails use.
  if (p === "/privacy" || p === "/install") {
    return new Response(null, { status: 301, headers: { location: `/#${p.slice(1)}`, "cache-control": "public, max-age=3600" } });
  }
  return empty(404);
}

export default {
  fetch(request, env, ctx) {
    return route(request, env, liveDeps(env), ctx);
  },
  async scheduled(controller, env, ctx) {
    const now = new Date(controller.scheduledTime);
    if (controller.cron === "0 4 1 * *") ctx.waitUntil(snapshot(env, now).then(() => {}));
    else ctx.waitUntil(cleanup(env, now));
  },
} satisfies ExportedHandler<Env>;
