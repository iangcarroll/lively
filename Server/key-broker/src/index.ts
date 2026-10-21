import { error, issueSonioxKey, json, nowSeconds, type Env } from "./broker";

// The entry module may only export handlers, so the logic lives in broker.ts.
export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);
    if (url.pathname === "/healthz") return json(200, { ok: true });
    if (url.pathname !== "/v1/soniox/key") return error(404, "not_found", "No such endpoint.");
    if (request.method !== "POST") return error(405, "method_not_allowed", "Use POST.");
    return issueSonioxKey(request, env, Date.now());
  },

  async scheduled(_controller: ScheduledController, env: Env): Promise<void> {
    await env.DB.prepare("DELETE FROM counters WHERE expires_at < ?").bind(nowSeconds(Date.now())).run();
  },
} satisfies ExportedHandler<Env>;
