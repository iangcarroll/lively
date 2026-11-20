import type { StaffReports } from "./reports";
import { accountPage, overviewPage, subscriptionsPage, type Access, type Section } from "./views";
import { styles } from "./styles";

const ORIGIN = "https://admin-lively.cautela.hk";
export interface ConsoleEnv {
  STAFF_READ_LIMIT: RateLimit;
  REPORTS: Pick<StaffReports, "overview" | "account" | "recentSubscriptions" | "subscription">;
  STAFF_ACCESS_AUD?: string;
  STAFF_SUPPORT_IDS?: string;
  STAFF_ANALYST_IDS?: string;
}

const securityHeaders = {
  "Cache-Control": "private, no-store",
  "Content-Security-Policy": "default-src 'none'; style-src 'self'; form-action 'self'; frame-ancestors 'none'; base-uri 'none'",
  "Referrer-Policy": "same-origin",
  "X-Content-Type-Options": "nosniff",
  "X-Frame-Options": "DENY",
  "X-Robots-Tag": "noindex, nofollow",
};

function response(body: string, status: number, type = "text/plain") {
  return new Response(body, { status, headers: { ...securityHeaders, "Content-Type": type + "; charset=utf-8" } });
}

function includes(ids: string | undefined, id: string) {
  return ids?.split(",").some(item => item.trim() === id) ?? false;
}

// Keep customer searches out of URLs, referrers and audit logs. Accept only a
// same-origin browser form with a bounded body, including chunked uploads.
async function readQuery(request: Request) {
  if (request.headers.get("Origin") !== ORIGIN ||
      request.headers.get("Content-Type")?.split(";")[0].trim() !== "application/x-www-form-urlencoded") return null;
  const reader = request.body?.getReader();
  if (!reader) return null;
  const decoder = new TextDecoder();
  let text = "", size = 0;
  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    size += value.length;
    if (size > 2048) { await reader.cancel(); return null; }
    text += decoder.decode(value, { stream: true });
  }
  const query = new URLSearchParams(text + decoder.decode()).get("q")?.trim();
  return query && query.length <= 254 ? query : null;
}

export default {
  async fetch(request: Request, env: ConsoleEnv, ctx: ExecutionContext): Promise<Response> {
    const url = new URL(request.url);
    if (url.origin !== ORIGIN) return response("Not found", 404);
    let operator: string | undefined;
    let action = "authorize";
    function audit(outcome: string) {
      console.info({ event: "lively_staff_access", operator: operator ?? null, action, outcome });
    }
    function denied() {
      audit("denied");
      return response("Staff access required.", 403);
    }
    try {
      if (!env.STAFF_ACCESS_AUD || ctx.access?.aud !== env.STAFF_ACCESS_AUD) return denied();
      const identity = await ctx.access.getIdentity();
      operator = identity?.user_uuid;
      if (!operator || !identity?.email) return denied();
      const access: Access = { support: includes(env.STAFF_SUPPORT_IDS, operator), analyst: includes(env.STAFF_ANALYST_IDS, operator) };
      if (!access.support && !access.analyst) return denied();
      if (url.search) return response("Use the search form.", 400);
      if (url.pathname === "/console.css" && request.method === "GET") return response(styles, 200, "text/css");
      const paths: Record<string, Section> = { "/": access.analyst ? "overview" : "users",
        "/overview": "overview", "/users": "users", "/subscriptions": "subscriptions" };
      if (!Object.hasOwn(paths, url.pathname)) return response("Not found", 404);
      const section = paths[url.pathname];
      action = section;
      if (section === "overview" ? !access.analyst : !access.support) return denied();
      if (!(await env.STAFF_READ_LIMIT.limit({ key: operator })).success) {
        audit("rate_limited");
        const res = response("Too many staff requests. Try again in a minute.", 429);
        res.headers.set("Retry-After", "60");
        return res;
      }
      let html: string;
      let outcome = "viewed";
      if (request.method === "GET") {
        if (section === "overview") html = overviewPage(access, await env.REPORTS.overview());
        else if (section === "users") html = accountPage(access);
        else html = subscriptionsPage(access, await env.REPORTS.recentSubscriptions());
      } else if (request.method === "POST" && section !== "overview") {
        action += "_lookup";
        const query = await readQuery(request);
        if (!query) { audit("invalid"); return response("Submit a valid lookup from the console.", 400); }
        if (section === "users") {
          const account = await env.REPORTS.account(query);
          outcome = account ? "found" : "no_match";
          html = accountPage(access, account);
        } else {
          const subscription = await env.REPORTS.subscription(query);
          outcome = subscription ? "found" : "no_match";
          html = subscriptionsPage(access, [], subscription);
        }
      } else return response("Method not allowed", 405);
      audit(outcome);
      return response(html, 200, "text/html");
    } catch {
      audit("unavailable");
      return response("Staff console temporarily unavailable. Try again.", 503);
    }
  },
} satisfies ExportedHandler<ConsoleEnv>;
