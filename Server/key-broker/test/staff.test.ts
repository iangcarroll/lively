import { exports as workers } from "cloudflare:workers";
import { createExecutionContext, env } from "cloudflare:test";
import { SignJWT, exportJWK, generateKeyPair, type JWTPayload, type JWK } from "jose";
import { beforeAll, beforeEach, afterEach, describe, expect, it, vi } from "vitest";
import staff, { type ConsoleEnv } from "../src/staff/console";
import { StaffReports } from "../src/staff/reports";
import { hash } from "../src/broker";
import { referenceHash } from "../src/staff/observations";
import broker from "../src/index";

const origin = "https://admin-lively.cautela.hk";
const audience = crypto.randomUUID();
const support = crypto.randomUUID();
const analyst = crypto.randomUUID();
const idp = crypto.randomUUID();
const issuer = "https://test-lively.cloudflareaccess.com";
const reports = new StaffReports(createExecutionContext(), env);
const bindings: ConsoleEnv = {
  STAFF_READ_LIMIT: { limit: async () => ({ success: true }) }, REPORTS: reports, STAFF_ACCESS_ISSUER: issuer,
  STAFF_ACCESS_AUD: audience, STAFF_IDP_ID: idp, STAFF_SUPPORT_IDS: support, STAFF_ANALYST_IDS: analyst,
};
const staffEmail = "staff@example.com";
const assertions = new Map<string, string>();
let signingKey: CryptoKey;
let jwk: JWK;

async function sign(subject: string, overrides: JWTPayload = {}, privateKey = signingKey) {
  const now = Math.floor(Date.now() / 1000);
  return new SignJWT({ iss: issuer, aud: [audience], iat: now, exp: now + 3600, nbf: now,
    type: "app", sub: subject, email: staffEmail, ...overrides })
    .setProtectedHeader({ alg: "RS256", kid: "staff-test" }).sign(privateKey);
}

beforeAll(async () => {
  const pair = await generateKeyPair("RS256");
  signingKey = pair.privateKey;
  jwk = { ...await exportJWK(pair.publicKey), alg: "RS256", kid: "staff-test" };
  for (const id of [support, analyst]) assertions.set(id, await sign(id));
});
beforeEach(() => {
  vi.spyOn(globalThis, "fetch").mockImplementation(async url => {
    if (String(url) !== issuer + "/cdn-cgi/access/certs") return new Response(null, { status: 503 });
    return Response.json({ keys: [jwk] });
  });
});
afterEach(() => vi.restoreAllMocks());

function context(id: string, aud = audience, email = staffEmail, overrides: Record<string, unknown> = {}) {
  const ctx = createExecutionContext();
  Object.defineProperty(ctx, "access", { value: { aud, getIdentity: async () => ({
    user_uuid: id, email, idp: { id: idp, type: "cloudflare" }, iat: Math.floor(Date.now() / 1000), ...overrides,
  }) } });
  return ctx;
}
function staffRequest(path: string, id: string, init: RequestInit = {}) {
  const headers = new Headers(init.headers);
  headers.set("Cf-Access-Jwt-Assertion", assertions.get(id)!);
  return new Request(origin + path, { ...init, headers });
}
function get(path: string, id: string) {
  return staff.fetch(staffRequest(path, id), bindings, context(id));
}
function lookup(path: string, query: string, id = support, initiator = origin) {
  return staff.fetch(staffRequest(path, id, { method: "POST", headers: { Origin: initiator },
    body: new URLSearchParams({ q: query }) }), bindings, context(id));
}

describe("staff access", () => {
  it("requires a platform-authenticated human in the configured application and role, on every route", async () => {
    for (const path of ["/", "/users", "/subscriptions", "/overview", "/console.css"]) {
      const req = staffRequest(path, support, { headers: { "Cf-Access-Authenticated-User-Email": staffEmail, Authorization: "Bearer customer" } });
      for (const ctx of [createExecutionContext(), context(support, "another-app"), context(crypto.randomUUID()), context(support, audience, "")]) {
        expect((await staff.fetch(req, bindings, ctx)).status).toBe(403);
      }
      expect((await staff.fetch(req, { REPORTS: reports, STAFF_READ_LIMIT: bindings.STAFF_READ_LIMIT }, context(support))).status).toBe(403);
      expect((await staff.fetch(new Request("https://alternate.workers.dev" + path), bindings, context(support))).status).toBe(404);
      if (path !== "/") expect((await broker.fetch(new Request("https://lively.cautela.hk" + path), env)).status).toBe(404);
    }
  });

  it("denies missing, mismatched and stale staff identities before invoking any report", async () => {
    const reportsCalled = vi.fn(() => { throw Error("Unexpected report access"); });
    const guarded = { ...bindings, REPORTS: { account: reportsCalled, recentSubscriptions: reportsCalled,
      subscription: reportsCalled, overview: reportsCalled } };
    const now = Math.floor(Date.now() / 1000);
    for (const path of ["/", "/users", "/subscriptions", "/console.css"]) {
      const req = staffRequest(path, support);
      const missingAssertion = new Request(origin + path, { headers: { "Cf-Access-Authenticated-User-Email": staffEmail } });
      const scenarios = [
        [missingAssertion, guarded, context(support)],
        [req, guarded, createExecutionContext()],
        [req, guarded, context(support, "another-audience")],
        [req, guarded, context(support, audience, staffEmail, { idp: { id: crypto.randomUUID(), type: "cloudflare" }, amr: ["hwk"] })],
        [req, guarded, context(support, audience, staffEmail, { idp: undefined })],
        [req, guarded, context(support, audience, staffEmail, { iat: now - 4 * 3600 })],
        [req, guarded, context(support, audience, staffEmail, { iat: now + 600 })],
        [req, guarded, context(support, audience, staffEmail, { iat: undefined })],
        [req, guarded, context(analyst)],
        [req, { ...guarded, STAFF_SUPPORT_IDS: "" }, context(support)],
        [req, { ...guarded, STAFF_IDP_ID: undefined }, context(support)],
        [req, { ...guarded, STAFF_ACCESS_ISSUER: undefined }, context(support)],
        [req, { ...guarded, STAFF_ACCESS_ISSUER: "https://untrusted.example" }, context(support)],
        [req, { ...guarded, STAFF_ACCESS_ISSUER: "https://unavailable.cloudflareaccess.com" }, context(support)],
      ] as const;
      for (const [request, policy, ctx] of scenarios) {
        expect((await staff.fetch(request, policy, ctx)).status).toBe(403);
      }
    }
    expect(reportsCalled).not.toHaveBeenCalled();
  });

  it("rejects invalid signatures, wrong claims, expired assertions and service credentials", async () => {
    const now = Math.floor(Date.now() / 1000);
    const other = await generateKeyPair("RS256");
    const rejected = [
      await sign(support, {}, other.privateKey),
      await sign(support, { iss: "https://different.cloudflareaccess.com" }),
      await sign(support, { aud: "different-app" }),
      await sign(support, { exp: now - 1 }),
      await sign(support, { exp: undefined }),
      await sign(support, { nbf: now + 300 }),
      await sign(support, { iat: now - 5 * 3600 }),
      await sign(support, { type: "org" }),
      await sign("", { email: undefined, common_name: "service" }),
      await sign(crypto.randomUUID()),
      "invalid",
    ];
    for (const assertion of rejected) {
      const req = new Request(origin + "/users", { headers: { "Cf-Access-Jwt-Assertion": assertion } });
      expect((await staff.fetch(req, bindings, context(support))).status).toBe(403);
    }
  });

  it("enforces both roles before querying and gives each a usable home", async () => {
    const spy = vi.spyOn(reports, "account");
    try {
      expect((await lookup("/users", "a@b.co", analyst)).status).toBe(403);
      expect(spy).not.toHaveBeenCalled();
      expect((await get("/subscriptions", analyst)).status).toBe(403);
      expect((await get("/overview", support)).status).toBe(403);
      expect(await (await get("/", analyst)).text()).toContain("<h1>Overview</h1>");
      expect(await (await get("/", support)).text()).toContain("<h1>Users</h1>");
      expect(await (await get("/", analyst)).text()).not.toContain('href="/users"');
    } finally { spy.mockRestore(); }
  });

  it("throttles authorized staff reads before reaching the service binding", async () => {
    const limit = vi.fn(async () => ({ success: false }));
    const res = await staff.fetch(staffRequest("/users", support, { method: "POST",
      headers: { Origin: origin }, body: new URLSearchParams({ q: "user@example.com" }) }),
      { ...bindings, STAFF_READ_LIMIT: { limit } }, context(support));
    expect(res.status).toBe(429);
    expect(limit).toHaveBeenCalledWith({ key: support });
    expect(res.headers.get("Retry-After")).toBe("60");
  });

  it("serves the overview over RPC when Cloudflare authenticates the analyst without reporting a sign-in method", async () => {
    const res = await staff.fetch(staffRequest("/", analyst), { ...bindings, REPORTS: workers.StaffReports }, context(analyst));
    expect(res.status).toBe(200);
    expect(await res.text()).toContain("<h1>Overview</h1>");
  });

  it("accepts only bounded same-origin form searches and disables caching on successes and failures", async () => {
    const responses = [
      await lookup("/users", "a@b.co", support, "https://sibling.example"),
      await lookup("/users", "x".repeat(3000)),
      await get("/users?q=private", support),
      await staff.fetch(staffRequest("/users", support, { method: "POST", body: "q=foo" }), bindings, context(support)),
    ];
    for (const res of responses) expect(res.status).toBe(400);
    for (const res of [...responses, await get("/users", support), await get("/users", analyst)]) {
      expect(res.headers.get("Cache-Control")).toContain("no-store");
      expect(res.headers.get("Content-Security-Policy")).toContain("frame-ancestors 'none'");
      expect(res.headers.get("Referrer-Policy")).toBe("same-origin");
    }
  });
});

describe("staff reports through the console", () => {
  beforeEach(async () => {
    await env.DB.batch(["users", "subscription_observations", "apple_ads_installs"].map(t => env.DB.prepare("DELETE FROM " + t)));
  });

  it("finds just the requested user and reports usable sessions without exposing stored credentials", async () => {
    const id = crypto.randomUUID(), secret = crypto.randomUUID(), email = 'a&b@example.com';
    await env.DB.prepare("INSERT INTO users (id,email,apple_sub,apple_refresh_token,free_pro) VALUES (?,?,?,?,1)")
      .bind(id, email, secret, secret).run();
    const now = Math.floor(Date.now() / 1000);
    for (const expires of [now + 1000, now - 1]) {
      await env.DB.prepare("INSERT INTO sessions (token_hash,user_id,expires_at) VALUES (?,?,?)")
        .bind(crypto.randomUUID(), id, expires).run();
    }
    const log = vi.spyOn(console, "info");
    try {
      for (const q of [id, email.toUpperCase()]) {
        const html = await (await lookup("/users", q)).text();
        expect(html).toContain("a&amp;b@example.com");
        expect(html).toContain("<dt>Unexpired sessions</dt><dd>1</dd>");
        expect(html).toContain("Granted");
        expect(html).not.toContain(secret);
      }
      expect(await (await lookup("/users", "a&b")).text()).toContain("No matching user");
      expect(log).toHaveBeenCalledWith(expect.objectContaining({ operator: support, action: "users_lookup", outcome: "found" }));
      expect(JSON.stringify(log.mock.calls)).not.toContain(email);
      const result = await reports.account(id);
      expect(Object.keys(result!)).not.toContain("apple_refresh_token");
    } finally { log.mockRestore(); }
  });

  it("imports legacy production payments for exact lookup with unknown plan and expiry", async () => {
    const reference = String(Math.floor(Math.random() * 1e12));
    const key = await hash("apple-ads-subscription:" + reference);
    const at = Math.floor(Date.now() / 1000);
    await env.DB.prepare("INSERT INTO apple_ads_subscriptions (subscription_hash,first_paid_at) VALUES (?,?)")
      .bind(key, at).run();
    // Reapply the data import from the migration against a preexisting payment.
    const migration = env.TEST_MIGRATIONS.find(m => m.name.startsWith("0007_"))!;
    const backfill = migration.queries.find(q => q.includes("FROM apple_ads_subscriptions"))!;
    await env.DB.prepare(backfill).run();
    expect(await reports.subscription(reference)).toMatchObject({
      store: "apple", event: "First payment", product: null, period_end_ms: null, observed_ms: at * 1000,
    });
    expect(await (await lookup("/subscriptions", reference)).text()).toContain("Unavailable");
  });

  it("shows a bounded recent list and can look up an older record outside it", async () => {
    const reference = String(Math.floor(Math.random() * 1e12));
    const now = Date.now();
    const rows = await Promise.all(Array.from({ length: 22 }, async (_, i) => {
      const key = await referenceHash("apple", i === 0 ? reference : String(i));
      return env.DB.prepare("INSERT INTO subscription_observations VALUES (?,?,'apple',?,?,?,NULL)")
        .bind(key, key, i === 0 ? "older-plan" : "pro.monthly", "Subscribed", now + i);
    }));
    await env.DB.batch(rows);
    expect(await reports.recentSubscriptions()).toHaveLength(20);
    expect(await (await get("/subscriptions", support)).text()).not.toContain("older-plan");
    expect(await (await lookup("/subscriptions", reference)).text()).toContain("older-plan");
    expect(await (await lookup("/subscriptions", "%")).text()).toContain("No matching subscription");
  });

  it("aggregates UTC creation dates, complimentary grants and stores independently of sign-ins", async () => {
    const day = 86400000, today = Math.floor(Date.now() / day) * day;
    const timestamps = [today - 14 * day, today - 13 * day, today, today];
    await env.DB.batch(timestamps.map((at, i) => env.DB.prepare("INSERT INTO users (id,email,created_at,free_pro) VALUES (?,?,?,?)")
      .bind(crypto.randomUUID(), crypto.randomUUID() + "@example.com", at / 1000, i % 2)));
    await env.DB.prepare("INSERT INTO subscription_observations VALUES (?1,NULL,'play',NULL,'Expired',?2,NULL)")
      .bind(crypto.randomUUID(), today).run();
    const overview = await reports.overview();
    expect(overview).toMatchObject({ accounts: timestamps.length, grants: 2, stores: [{ store: "play", count: 1 }] });
    expect(overview.days.map(d => d.count)).toEqual([1, ...Array(12).fill(0), 2]);
    expect(await (await get("/overview", analyst)).text()).not.toContain("@example.com");
  });

  it("retains recent or unexpired observations during scheduled cleanup", async () => {
    const now = Date.now();
    const old = now - 91 * 86_400_000;
    await env.DB.batch([[old, null], [old, now + 1000], [now, null]].map(([at, end], i) =>
      env.DB.prepare("INSERT INTO subscription_observations VALUES (?,NULL,'play',NULL,'Active',?,?)")
        .bind(String(i), at, end)));
    await broker.scheduled({} as ScheduledController, env);
    expect((await reports.recentSubscriptions()).map(r => r.period_end_ms)).toEqual([null, now + 1000]);
  });
});
