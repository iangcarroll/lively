import { X509Certificate } from "node:crypto";
import { env } from "cloudflare:test";
import { afterEach, beforeEach, describe, expect, it, type Mock, vi } from "vitest";
import { isAppleIntermediate, type SignedTransaction } from "../src/appstore";
import { hash, type Env } from "../src/broker";
import worker from "../src/index";
import {
  APPLE_WWDR_G6,
  TEST_INTERMEDIATE,
  TEST_LEAF,
  TEST_LEAF_KEY,
  TEST_PLAIN_LEAF,
  TEST_PLAIN_LEAF_KEY,
  TEST_ROOT,
} from "./appstore-fixtures";

const DAY = 86_400_000;

let soniox: Mock<typeof fetch>;
let send: Mock<SendEmail["send"]>;
/** Trusts the test root instead of Apple's. */
let local: Env;

beforeEach(() => {
  soniox = vi.fn<typeof fetch>(async () =>
    Response.json({ api_key: `temp:${crypto.randomUUID()}`, expires_at: "2026-10-20T12:05:30Z" }),
  );
  vi.spyOn(globalThis, "fetch").mockImplementation(soniox);
  send = vi.fn(async () => ({ messageId: crypto.randomUUID() })) as Mock<SendEmail["send"]>;
  local = { ...env, APP_STORE_TEST_ROOT: TEST_ROOT, EMAIL: { send } as SendEmail };
});

afterEach(() => vi.restoreAllMocks());

function base64url(bytes: Uint8Array | string): string {
  const binary = typeof bytes === "string" ? bytes : String.fromCharCode(...bytes);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

/** Signs `payload` the way the App Store does, with the test chain. */
async function sign(
  payload: object,
  { leaf = TEST_LEAF, key = TEST_LEAF_KEY }: { leaf?: string; key?: string } = {},
): Promise<string> {
  const header = base64url(JSON.stringify({ alg: "ES256", x5c: [leaf, TEST_INTERMEDIATE, TEST_ROOT] }));
  const body = base64url(new TextEncoder().encode(JSON.stringify(payload)));
  const privateKey = await crypto.subtle.importKey(
    "pkcs8",
    Uint8Array.from(atob(key), (c) => c.charCodeAt(0)),
    { name: "ECDSA", namedCurve: "P-256" },
    false,
    ["sign"],
  );
  const signature = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, privateKey, new TextEncoder().encode(`${header}.${body}`));
  return `${header}.${body}.${base64url(new Uint8Array(signature))}`;
}

function transaction(overrides: Partial<SignedTransaction> = {}): SignedTransaction {
  const now = Date.now();
  return {
    originalTransactionId: String(2_000_000_000_000_000 + Math.floor(Math.random() * 1e12)),
    productId: "hk.cautela.lively.pro.monthly",
    bundleId: env.APP_BUNDLE_ID,
    environment: "Production",
    type: "Auto-Renewable Subscription",
    signedDate: now - DAY,
    expiresDate: now + 29 * DAY,
    ...overrides,
  };
}

function keyRequest({ subscription, token, installID = crypto.randomUUID(), ip = randomIP() }: { subscription?: string; token?: string; installID?: string; ip?: string } = {}): Request {
  const headers: Record<string, string> = { "Lively-Install-ID": installID, "CF-Connecting-IP": ip };
  if (subscription !== undefined) headers["Lively-Subscription"] = subscription;
  if (token !== undefined) headers.Authorization = `Bearer ${token}`;
  return new Request("https://broker.test/v1/soniox/key", { method: "POST", headers, cf: { country: "US" } } as RequestInit);
}

function randomIP(): string {
  return `10.${Math.floor(Math.random() * 256)}.${Math.floor(Math.random() * 256)}.${Math.floor(Math.random() * 256)}`;
}

async function planOf(response: Response): Promise<string> {
  expect(response.status).toBe(200);
  return (await response.json<{ plan: string }>()).plan;
}

function sentToSoniox(): { client_reference_id: string; max_session_duration_seconds: number } {
  return JSON.parse((soniox.mock.calls.at(-1) as [string, RequestInit])[1].body as string);
}

function notification(signedPayload: string): Request {
  return new Request("https://broker.test/v1/appstore/notifications", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ signedPayload }),
  });
}

async function notify(type: string, t: SignedTransaction): Promise<Response> {
  const signedTransactionInfo = await sign(t);
  return worker.fetch(
    notification(await sign({ notificationType: type, signedDate: Date.now(), data: { bundleId: t.bundleId, environment: t.environment, signedTransactionInfo } })),
    local,
  );
}

describe("Apple's chain", () => {
  it("trusts Apple's real App Store intermediate under Apple Root CA - G3", () => {
    expect(isAppleIntermediate(new X509Certificate(Uint8Array.from(atob(APPLE_WWDR_G6), (c) => c.charCodeAt(0))))).toBe(true);
  });

  it("doesn't trust an intermediate under another root", () => {
    expect(isAppleIntermediate(new X509Certificate(Uint8Array.from(atob(TEST_INTERMEDIATE), (c) => c.charCodeAt(0))))).toBe(false);
  });
});

describe("Pro subscriptions", () => {
  it("is free without a subscription", async () => {
    expect(await planOf(await worker.fetch(keyRequest(), local))).toBe("free");
  });

  it("gives an active subscription Pro, charged to the subscription", async () => {
    const t = transaction();
    expect(await planOf(await worker.fetch(keyRequest({ subscription: await sign(t) }), local))).toBe("pro");
    const sent = sentToSoniox();
    expect(sent.client_reference_id).toBe(await hash(`subscription:${t.originalTransactionId}`));
    expect(sent.max_session_duration_seconds).toBe(7200);
  });

  it.each(["Production", "Sandbox"])("accepts both configured products in %s for the current app", async (environment) => {
    for (const productId of env.APP_STORE_PRODUCT_IDS.split(",")) {
      const t = transaction({ productId, environment });
      expect(await planOf(await worker.fetch(keyRequest({ subscription: await sign(t) }), local))).toBe("pro");
      expect(sentToSoniox().client_reference_id).toBe(await hash(`subscription:${t.originalTransactionId}`));
    }
  });

  it("does not grant Apple Pro for products configured only for Google Play", async () => {
    for (const productId of env.PLAY_PRODUCT_IDS.split(",")) {
      const jws = await sign(transaction({ productId, environment: "Sandbox" }));
      expect(await planOf(await worker.fetch(keyRequest({ subscription: jws }), local))).toBe("free");
    }
  });

  it("shares one subscription's budget across installs and IPs", async () => {
    const strict = { ...local, PRO_MINUTES_PER_DAY: "4" };
    const jws = await sign(transaction());
    expect((await worker.fetch(keyRequest({ subscription: jws }), strict)).status).toBe(200);
    expect((await worker.fetch(keyRequest({ subscription: jws }), strict)).status).toBe(200);
    const over = await worker.fetch(keyRequest({ subscription: jws }), strict);
    expect(over.status).toBe(429);
    expect(await over.json()).toMatchObject({ message: "Today's translation time is used up.", plan: "pro" });
  });

  it("isn't held to the per-IP daily budget", async () => {
    const strict = { ...local, PER_IP_MINUTES_PER_DAY: "2" };
    const ip = randomIP();
    const jws = await sign(transaction());
    for (let i = 0; i < 3; i++) expect((await worker.fetch(keyRequest({ subscription: jws, ip }), strict)).status).toBe(200);
  });

  it("takes the subscription's budget over a signed-in account's", async () => {
    const t = transaction();
    const { token } = await signIn();
    expect(await planOf(await worker.fetch(keyRequest({ subscription: await sign(t), token }), local))).toBe("pro");
    expect(sentToSoniox().client_reference_id).toBe(await hash(`subscription:${t.originalTransactionId}`));
  });

  it("accepts an old transaction whose period hasn't ended", async () => {
    const t = transaction({ productId: "hk.cautela.lively.pro.yearly", signedDate: Date.now() - 200 * DAY, expiresDate: Date.now() + 165 * DAY });
    expect(await planOf(await worker.fetch(keyRequest({ subscription: await sign(t) }), local))).toBe("pro");
  });

  it.each<[string, Partial<SignedTransaction>]>([
    ["expired", { expiresDate: Date.now() - 1000 }],
    ["revoked", { revocationDate: Date.now() - DAY }],
    ["another app's", { bundleId: "com.example.other" }],
    ["old developer account's", { bundleId: "sh.ian.lively" }],
    ["another product's", { productId: "sh.ian.lively.tip" }],
    ["Xcode's local", { environment: "Xcode" }],
    ["no expiry", { expiresDate: undefined }],
  ])("ignores an %s transaction", async (_, overrides) => {
    expect(await planOf(await worker.fetch(keyRequest({ subscription: await sign(transaction(overrides)) }), local))).toBe("free");
  });

  it("ignores a transaction whose payload was changed", async () => {
    const [header, , signature] = (await sign(transaction({ expiresDate: Date.now() - 1000 }))).split(".");
    const forged = base64url(new TextEncoder().encode(JSON.stringify(transaction())));
    expect(await planOf(await worker.fetch(keyRequest({ subscription: `${header}.${forged}.${signature}` }), local))).toBe("free");
  });

  it("ignores a certificate without the App Store marker, though it chains to the root", async () => {
    const jws = await sign(transaction(), { leaf: TEST_PLAIN_LEAF, key: TEST_PLAIN_LEAF_KEY });
    expect(await planOf(await worker.fetch(keyRequest({ subscription: jws }), local))).toBe("free");
  });

  it("ignores a chain that isn't under Apple's root", async () => {
    // `env` trusts only Apple Root CA - G3.
    expect(await planOf(await worker.fetch(keyRequest({ subscription: await sign(transaction()) }), env))).toBe("free");
  });

  it.each(["", "garbage", "a.b.c", "x".repeat(5000)])("ignores %j", async (subscription) => {
    expect(await planOf(await worker.fetch(keyRequest({ subscription }), local))).toBe("free");
  });

  it("denies subscriptions in the denylist", async () => {
    const t = transaction();
    await env.DB.prepare("INSERT INTO denylist (install_hash, reason) VALUES (?, 'test')").bind(await hash(`subscription:${t.originalTransactionId}`)).run();
    expect((await worker.fetch(keyRequest({ subscription: await sign(t) }), local)).status).toBe(403);
  });
});

describe("App Store notifications", () => {
  it("ignores refunds for replaced products without revoking a current subscription", async () => {
    const t = transaction({ environment: "Sandbox" });
    const jws = await sign(t);
    for (const productId of env.PLAY_PRODUCT_IDS.split(",")) {
      expect((await notify("REFUND", { ...t, productId })).status).toBe(200);
    }
    expect(await planOf(await worker.fetch(keyRequest({ subscription: jws }), local))).toBe("pro");
    expect((await notify("REFUND", t)).status).toBe(200);
    expect(await planOf(await worker.fetch(keyRequest({ subscription: jws }), local))).toBe("free");
  });

  it("ignores refunds from the old app even when the transaction ID matches the current app", async () => {
    const t = transaction({ environment: "Sandbox" });
    const jws = await sign(t);
    expect(await planOf(await worker.fetch(keyRequest({ subscription: jws }), local))).toBe("pro");

    expect((await notify("REFUND", { ...t, bundleId: "sh.ian.lively" })).status).toBe(200);
    expect(await planOf(await worker.fetch(keyRequest({ subscription: jws }), local))).toBe("pro");

    expect((await notify("REFUND", t)).status).toBe(200);
    expect(await planOf(await worker.fetch(keyRequest({ subscription: jws }), local))).toBe("free");
  });

  it("stops Pro for a refunded subscription, and restores it if the refund is reversed", async () => {
    const t = transaction();
    const jws = await sign(t);
    expect(await planOf(await worker.fetch(keyRequest({ subscription: jws }), local))).toBe("pro");

    expect((await notify("REFUND", t)).status).toBe(200);
    expect(await planOf(await worker.fetch(keyRequest({ subscription: jws }), local))).toBe("free");

    expect((await notify("REFUND_REVERSED", t)).status).toBe(200);
    expect(await planOf(await worker.fetch(keyRequest({ subscription: jws }), local))).toBe("pro");
  });

  it("stops Pro for a revoked Family Sharing subscription", async () => {
    const t = transaction();
    expect((await notify("REVOKE", t)).status).toBe(200);
    expect(await planOf(await worker.fetch(keyRequest({ subscription: await sign(t) }), local))).toBe("free");
  });

  it("acknowledges other types and other apps without acting on them", async () => {
    const t = transaction();
    expect((await notify("DID_RENEW", t)).status).toBe(200);
    const other = transaction({ bundleId: "com.example.other" });
    expect((await notify("REFUND", other)).status).toBe(200);
    const row = await env.DB.prepare("SELECT 1 FROM revoked_subscriptions WHERE original_transaction_id IN (?1, ?2)")
      .bind(t.originalTransactionId, other.originalTransactionId)
      .first();
    expect(row).toBeNull();
  });

  it("rejects a notification not signed by the App Store", async () => {
    const t = transaction();
    const forged = await sign(
      { notificationType: "REFUND", signedDate: Date.now(), data: { signedTransactionInfo: await sign(t) } },
      { leaf: TEST_PLAIN_LEAF, key: TEST_PLAIN_LEAF_KEY },
    );
    expect((await worker.fetch(notification(forged), local)).status).toBe(400);
    expect((await worker.fetch(notification("nope"), local)).status).toBe(400);
  });
});

function post(path: string, body: unknown, token?: string): Request {
  const headers: Record<string, string> = { "Content-Type": "application/json", "CF-Connecting-IP": randomIP() };
  if (token !== undefined) headers.Authorization = `Bearer ${token}`;
  return new Request(`https://broker.test${path}`, { method: "POST", headers, body: JSON.stringify(body) });
}

async function signIn(email = `${crypto.randomUUID()}@example.com`): Promise<{ token: string; user: { id: string; email: string; free_pro: boolean } }> {
  expect((await worker.fetch(post("/v1/auth/email/start", { email }), local)).status).toBe(200);
  const message = send.mock.calls.at(-1)?.[0] as EmailMessageBuilder;
  const code = /\b(\d{6})\b/.exec(message.subject)![1];
  const response = await worker.fetch(post("/v1/auth/email/verify", { email, code }), local);
  expect(response.status).toBe(200);
  return response.json();
}

function me(token: string): Promise<Response> {
  return worker.fetch(new Request("https://broker.test/v1/auth/me", { headers: { Authorization: `Bearer ${token}` } }), local);
}

describe("free Pro accounts", () => {
  it("gives Pro to an account granted free_pro", async () => {
    const { token, user } = await signIn();
    expect(user.free_pro).toBe(false);
    expect(await planOf(await worker.fetch(keyRequest({ token }), local))).toBe("free");

    await env.DB.prepare("UPDATE users SET free_pro = 1 WHERE email = ?").bind(user.email).run();
    expect(await planOf(await worker.fetch(keyRequest({ token }), local))).toBe("pro");
    expect(sentToSoniox().client_reference_id).toBe(await hash(`user:${user.id}`));
    expect(sentToSoniox().max_session_duration_seconds).toBe(7200);
    expect(await (await me(token)).json()).toMatchObject({ user: { free_pro: true } });
  });

  it("grandfathers every account that existed before Pro", async () => {
    // Migration 0003 ran when the test database was made, so redo its UPDATE.
    const { token } = await signIn();
    await env.DB.prepare("UPDATE users SET free_pro = 1").run();
    expect(await planOf(await worker.fetch(keyRequest({ token }), local))).toBe("pro");
    await env.DB.prepare("UPDATE users SET free_pro = 0").run();
  });
});

describe("account deletion", () => {
  it("deletes the account and signs out every session", async () => {
    const email = `${crypto.randomUUID()}@example.com`;
    const first = await signIn(email);
    const second = await signIn(email);
    expect(second.user.id).toBe(first.user.id);

    expect((await worker.fetch(post("/v1/auth/delete", {}, first.token), local)).status).toBe(200);
    expect(await env.DB.prepare("SELECT 1 FROM users WHERE email = ?").bind(email).first()).toBeNull();
    expect(await env.DB.prepare("SELECT 1 FROM sessions WHERE user_id = ?").bind(first.user.id).first()).toBeNull();
    expect((await me(first.token)).status).toBe(401);
    expect((await me(second.token)).status).toBe(401);
    expect((await worker.fetch(keyRequest({ token: second.token }), local)).status).toBe(401);

    // Signing in again makes a new account.
    expect((await signIn(email)).user.id).not.toBe(first.user.id);
  });

  it("needs a signed-in token", async () => {
    expect((await worker.fetch(post("/v1/auth/delete", {}), local)).status).toBe(401);
    expect((await worker.fetch(post("/v1/auth/delete", {}, "nope"), local)).status).toBe(401);
  });
});

describe("pages", () => {
  it.each(["/", "/privacy", "/support", "/terms", "/delete-account"])("redirects legacy %s to a working canonical page", async (path) => {
    const original = new URL(path, "https://lively.ian.sh");
    original.searchParams.set("source", crypto.randomUUID());
    const redirect = await worker.fetch(new Request(original), local);
    expect(redirect.status).toBe(308);
    const destination = new URL(redirect.headers.get("Location")!);
    expect(destination.origin).toBe("https://lively.cautela.hk");
    expect(destination.pathname).toBe(original.pathname);
    expect(destination.search).toBe(original.search);
    const page = await worker.fetch(new Request(destination), local);
    expect(page.status).toBe(200);
    expect(page.headers.get("Content-Type")).toContain("text/html");
    const body = await page.text();
    for (const match of body.matchAll(/href="(\/[^\"]*)"/g)) {
      expect((await worker.fetch(new Request(new URL(match[1], destination)), local)).status).toBe(200);
    }
  });

  it.each(["/privacy", "/support", "/terms", "/delete-account"])("serves %s with the support email", async (path) => {
    const response = await worker.fetch(new Request(`https://broker.test${path}`), local);
    expect(response.status).toBe(200);
    const body = await response.text();
    expect(body).toContain("support@lively.cautela.hk");
    expect(body).not.toContain("github.com");
  });

  it("serves a protected account deletion flow", async () => {
    const page = await worker.fetch(new Request("https://broker.test/delete-account"), local);
    expect(page.headers.get("Content-Security-Policy")).toContain("script-src 'self'");
    expect(await page.text()).toContain("Delete account permanently");

    const script = await worker.fetch(new Request("https://broker.test/delete-account.js"), local);
    expect(script.headers.get("Content-Type")).toContain("text/javascript");
    expect(await script.text()).toContain("/v1/auth/delete");
  });
});

describe("Apple Ads keyword to paid Pro subscription", () => {
  beforeEach(async () => {
    await env.DB.batch([env.DB.prepare("DELETE FROM apple_ads_installs"), env.DB.prepare("DELETE FROM apple_ads_subscriptions")]);
  });

  const install = () => crypto.randomUUID();
  const campaign = Number(env.APPLE_ADS_CAMPAIGN_IDS.split(",")[0]);
  const record = { attribution: true, campaignId: campaign, adGroupId: 37, keywordId: 55, claimType: "Click", conversionType: "Download" };
  const token = () => btoa(crypto.randomUUID());

  function lookup(id: string, body = token()) {
    return worker.fetch(new Request("https://broker.test/v1/apple-ads/attribution", {
      method: "POST", headers: { "Lively-Attribution-ID": id, "CF-Connecting-IP": randomIP() }, body,
    }), local);
  }

  function purchase(id: string, overrides: Partial<SignedTransaction> = {}) {
    const t = transaction();
    return { ...t, purchaseDate: Date.now(), transactionId: t.originalTransactionId, appAccountToken: id,
      inAppOwnershipType: "PURCHASED", price: 4990, ...overrides };
  }

  const report = () => env.DB.prepare("SELECT * FROM apple_ads_keyword_conversions ORDER BY keyword_id").all();

  it("joins verified purchases before or after token delivery and counts each original subscription once", async () => {
    const [a, b] = [install(), install()];
    const keyword = await env.DB.prepare("SELECT * FROM apple_ads_keywords LIMIT 1")
      .first<{ campaign_id: number; ad_group_id: number; keyword_id: number; keyword: string; match_type: string }>();
    if (!keyword) throw Error("Keyword catalogue missing");
    const mapped = { ...record, campaignId: keyword.campaign_id, adGroupId: keyword.ad_group_id, keywordId: keyword.keyword_id };
    const first = purchase(a);
    await notify("SUBSCRIBED", first);
    await notify("SUBSCRIBED", first);
    soniox.mockImplementation(async () => Response.json(mapped));
    const appleToken = token();
    expect(await (await lookup(a, appleToken)).json()).toEqual({ attributed: true });
    expect(soniox).toHaveBeenCalledWith("https://api-adservices.apple.com/api/v1/", expect.objectContaining({
      method: "POST", headers: { "Content-Type": "text/plain" }, body: appleToken,
    }));
    expect(await (await lookup(a, appleToken)).json()).toEqual({ attributed: true });
    expect(soniox).toHaveBeenCalledTimes(1);
    expect(await (await lookup(b, appleToken)).json()).toEqual({ attributed: false });
    await lookup(b);
    await notify("DID_RENEW", { ...first, transactionId: "renewal", appAccountToken: b, purchaseDate: first.purchaseDate + DAY });
    expect((await report()).results).toMatchObject([{ keyword: keyword.keyword, match_type: keyword.match_type, installs: 2, paid_subscriptions: 1 }]);
    await notify("SUBSCRIBED", purchase(b));
    expect((await report()).results[0].paid_subscriptions).toBe(2);
  });

  it("binds trial conversions to the original install even across out-of-order renewal delivery", async () => {
    const id = install();
    soniox.mockImplementation(async () => Response.json({ ...record, keywordId: undefined }));
    await lookup(id);
    const trial = purchase(id, { price: 0 });
    const paid = { ...trial, transactionId: "later", price: 4990, purchaseDate: trial.purchaseDate + DAY };
    await notify("DID_RENEW", paid);
    expect((await report()).results).toMatchObject([{ keyword_id: null, installs: 1, paid_subscriptions: 0 }]);
    await notify("SUBSCRIBED", trial);
    await notify("DID_RENEW", paid);
    expect((await report()).results[0].paid_subscriptions).toBe(1);
    expect(await env.DB.prepare("SELECT first_paid_at FROM apple_ads_subscriptions").first("first_paid_at")).toBe(Math.floor(paid.purchaseDate / 1000));
  });

  it("excludes sandbox, free, family, legacy, revoked and unverified purchases", async () => {
    const id = install();
    soniox.mockImplementation(async () => Response.json(record));
    await lookup(id);
    for (const overrides of [{ environment: "Sandbox" }, { price: 0 }, { price: undefined }, { inAppOwnershipType: "FAMILY_SHARED" },
      { appAccountToken: undefined }, { revocationDate: Date.now() }, { productId: "another.app.pro" }]) {
      await notify("SUBSCRIBED", purchase(id, overrides));
    }
    expect((await worker.fetch(notification("not.signed.proof"), local)).status).toBe(400);
    expect((await report()).results).toMatchObject([{ installs: 1, paid_subscriptions: 0 }]);
  });

  it("retries Apple's delayed token and excludes organic, developer and malformed responses", async () => {
    const id = install();
    soniox.mockResolvedValueOnce(new Response(null, { status: 404 }));
    const retry = await lookup(id);
    expect(retry.status).toBe(503);
    expect(retry.headers.get("Retry-After")).toBe("5");
    for (const payload of [{ attribution: false }, { ...record, campaignId: 1234567890 }]) {
      soniox.mockResolvedValueOnce(Response.json(payload));
      expect(await (await lookup(id)).json()).toEqual({ attributed: false });
    }
    soniox.mockResolvedValueOnce(Response.json({}));
    expect((await lookup(id)).status).toBe(503);
    expect((await lookup("invalid")).status).toBe(400);
    expect((await lookup(id, "x".repeat(16385))).status).toBe(400);
    expect((await report()).results).toHaveLength(0);
  });
});
