import { deleteExpiredAuth, logout, me, startEmailSignIn, verifyEmailSignIn } from "./auth";
import { error, issueSonioxKey, json, nowSeconds, type Env } from "./broker";

const ROUTES: Record<string, { method: string; handle: (request: Request, env: Env, now: number) => Promise<Response> }> = {
  "/v1/soniox/key": { method: "POST", handle: issueSonioxKey },
  "/v1/auth/email/start": { method: "POST", handle: startEmailSignIn },
  "/v1/auth/email/verify": { method: "POST", handle: verifyEmailSignIn },
  "/v1/auth/me": { method: "GET", handle: me },
  "/v1/auth/logout": { method: "POST", handle: logout },
};

// The entry module may only export handlers, so the logic lives in broker.ts.
export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);
    if (url.pathname === "/healthz") return json(200, { ok: true });
    const route = Object.hasOwn(ROUTES, url.pathname) ? ROUTES[url.pathname] : undefined;
    if (!route) return error(404, "not_found", "No such endpoint.");
    if (request.method !== route.method) return error(405, "method_not_allowed", `Use ${route.method}.`);
    return route.handle(request, env, Date.now());
  },

  async scheduled(_controller: ScheduledController, env: Env): Promise<void> {
    const now = Date.now();
    await env.DB.prepare("DELETE FROM counters WHERE expires_at < ?").bind(nowSeconds(now)).run();
    await deleteExpiredAuth(env, now);
  },
} satisfies ExportedHandler<Env>;
