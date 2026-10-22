import { env } from "cloudflare:test";
import { afterEach, beforeAll, beforeEach, describe, expect, it, type Mock, vi } from "vitest";
import { hash, type Env } from "../src/broker";
import worker from "../src/index";
import { resetPlayCaches, type SubscriptionPurchaseV2 } from "../src/play";

const DAY = 86_400_000;
const TOKEN_URL = "https://oauth2.googleapis.com/token";
const PLAY_API = "https://androidpublisher.googleapis.com/androidpublisher/v3/applications/sh.ian.lively/purchases/subscriptionsv2/tokens/";

/** A throwaway service account, and its public key to check the broker's JWTs with. */
let serviceAccount: string;
let publicKey: CryptoKey;
let local: Env;

/** Play's answer per purchase token; a number is an HTTP error status. */
let purchases: Map<string, SubscriptionPurchaseV2 | number>;
let oauthStatus: number;
let fetchMock: Mock<typeof fetch>;

beforeAll(async () => {
  const pair = (await crypto.subtle.generateKey(
    { name: "RSASSA-PKCS1-v1_5", modulusLength: 2048, publicExponent: new Uint8Array([1, 0, 1]), hash: "SHA-256" },
    true,
    ["sign", "verify"],
  )) as CryptoKeyPair;
  publicKey = pair.publicKey;
  const pkcs8 = new Uint8Array((await crypto.subtle.exportKey("pkcs8", pair.privateKey)) as ArrayBuffer);
  const pem = `-----BEGIN PRIVATE KEY-----\n${btoa(String.fromCharCode(...pkcs8)).replace(/.{64}/g, "$&\n")}\n-----END PRIVATE KEY-----\n`;
  serviceAccount = JSON.stringify({
    type: "service_account",
    project_id: "lively-test",
    private_key: pem,
    client_email: "broker@lively-test.iam.gserviceaccount.com",
    token_uri: TOKEN_URL,
  });
});

beforeEach(() => {
  resetPlayCaches();
  purchases = new Map();
  oauthStatus = 200;
  local = { ...env, GOOGLE_PLAY_SERVICE_ACCOUNT: serviceAccount };
  fetchMock = vi.fn<typeof fetch>(async (input, init) => {
    const url = input instanceof Request ? input.url : String(input);
    if (url === TOKEN_URL) {
      if (oauthStatus !== 200) return new Response("nope", { status: oauthStatus });
      const assertion = new URLSearchParams(String(init?.body)).get("assertion") ?? "";
      if (!(await verifyJWT(assertion))) return new Response("bad assertion", { status: 400 });
      return Response.json({ access_token: "google-access-token", expires_in: 3599, token_type: "Bearer" });
    }
    if (url.startsWith(PLAY_API)) {
      if (new Headers(init?.headers).get("Authorization") !== "Bearer google-access-token") return new Response("", { status: 401 });
      const answer = purchases.get(decodeURIComponent(url.slice(PLAY_API.length)));
      if (answer === undefined) return Response.json({ error: { code: 404 } }, { status: 404 });
      if (typeof answer === "number") return new Response("error", { status: answer });
      return Response.json(answer);
    }
    return Response.json({ api_key: `temp:${crypto.randomUUID()}`, expires_at: "2026-10-20T12:05:30Z" });
  });
  vi.spyOn(globalThis, "fetch").mockImplementation(fetchMock);
});

afterEach(() => vi.restoreAllMocks());

async function verifyJWT(jwt: string): Promise<boolean> {
  const [header, payload, signature] = jwt.split(".");
  if (!signature) return false;
  const ok = await crypto.subtle.verify("RSASSA-PKCS1-v1_5", publicKey, fromBase64url(signature), new TextEncoder().encode(`${header}.${payload}`));
  const claims = JSON.parse(new TextDecoder().decode(fromBase64url(payload))) as { iss?: string; scope?: string; aud?: string };
  return (
    ok &&
    JSON.parse(new TextDecoder().decode(fromBase64url(header))).alg === "RS256" &&
    claims.iss === "broker@lively-test.iam.gserviceaccount.com" &&
    claims.scope === "https://www.googleapis.com/auth/androidpublisher" &&
    claims.aud === TOKEN_URL
  );
}

function fromBase64url(value: string): Uint8Array {
  const padded = value.replace(/-/g, "+").replace(/_/g, "/");
  return Uint8Array.from(atob(padded + "=".repeat((4 - (padded.length % 4)) % 4)), (c) => c.charCodeAt(0));
}

/** A fresh purchase token that Play knows as `purchase`. */
function token(purchase?: SubscriptionPurchaseV2 | number): string {
  const t = `${crypto.randomUUID().replace(/-/g, "")}.AO-J1Oz_${crypto.randomUUID()}`;
  if (purchase !== undefined) purchases.set(t, purchase);
  return t;
}

function purchase(overrides: Partial<SubscriptionPurchaseV2> = {}): SubscriptionPurchaseV2 {
  return {
    subscriptionState: "SUBSCRIPTION_STATE_ACTIVE",
    lineItems: [{ productId: "sh.ian.lively.pro.monthly", expiryTime: new Date(Date.now() + 29 * DAY).toISOString() }],
    ...overrides,
  };
}

function keyRequest(playPurchase?: string): Request {
  const headers: Record<string, string> = { "Lively-Install-ID": crypto.randomUUID(), "CF-Connecting-IP": randomIP() };
  if (playPurchase !== undefined) headers["Lively-Play-Purchase"] = playPurchase;
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
  const call = fetchMock.mock.calls.filter(([url]) => String(url).includes("soniox")).at(-1) as [string, RequestInit];
  return JSON.parse(call[1].body as string);
}

function callsTo(prefix: string): number {
  return fetchMock.mock.calls.filter(([url]) => String(url).startsWith(prefix)).length;
}

describe("Google Play subscriptions", () => {
  it("gives an active subscription Pro, charged to the purchase token", async () => {
    const t = token(purchase());
    expect(await planOf(await worker.fetch(keyRequest(t), local))).toBe("pro");
    const sent = sentToSoniox();
    expect(sent.client_reference_id).toBe(await hash(`subscription:play:${await hash(`play:${t}`)}`));
    expect(sent.max_session_duration_seconds).toBe(7200);
  });

  it.each<[string, Partial<SubscriptionPurchaseV2>]>([
    ["in grace period", { subscriptionState: "SUBSCRIPTION_STATE_IN_GRACE_PERIOD" }],
    ["cancelled but paid through", { subscriptionState: "SUBSCRIPTION_STATE_CANCELED" }],
    ["yearly", { lineItems: [{ productId: "sh.ian.lively.pro.yearly", expiryTime: new Date(Date.now() + 300 * DAY).toISOString() }] }],
  ])("gives Pro to a subscription %s", async (_, overrides) => {
    expect(await planOf(await worker.fetch(keyRequest(token(purchase(overrides))), local))).toBe("pro");
  });

  it.each<[string, Partial<SubscriptionPurchaseV2>]>([
    ["expired", { subscriptionState: "SUBSCRIPTION_STATE_EXPIRED" }],
    ["on hold", { subscriptionState: "SUBSCRIPTION_STATE_ON_HOLD" }],
    ["paused", { subscriptionState: "SUBSCRIPTION_STATE_PAUSED" }],
    ["pending", { subscriptionState: "SUBSCRIPTION_STATE_PENDING" }],
    ["active but past its expiry", { lineItems: [{ productId: "sh.ian.lively.pro.monthly", expiryTime: new Date(Date.now() - 1000).toISOString() }] }],
    ["cancelled and past its expiry", { subscriptionState: "SUBSCRIPTION_STATE_CANCELED", lineItems: [{ productId: "sh.ian.lively.pro.monthly", expiryTime: new Date(Date.now() - 1000).toISOString() }] }],
    ["another product's", { lineItems: [{ productId: "sh.ian.lively.tip", expiryTime: new Date(Date.now() + DAY).toISOString() }] }],
    ["line-item-less", { lineItems: [] }],
  ])("ignores an %s subscription", async (_, overrides) => {
    expect(await planOf(await worker.fetch(keyRequest(token(purchase(overrides))), local))).toBe("free");
  });

  it("ignores test purchases unless PLAY_ALLOW_TEST_PURCHASES is true", async () => {
    const t = token(purchase({ testPurchase: {} }));
    expect(await planOf(await worker.fetch(keyRequest(t), { ...local, PLAY_ALLOW_TEST_PURCHASES: "false" }))).toBe("free");
    resetPlayCaches();
    expect(await planOf(await worker.fetch(keyRequest(t), { ...local, PLAY_ALLOW_TEST_PURCHASES: "true" }))).toBe("pro");
  });

  it.each([404, 410, 400])("ignores a token Google answers %i for", async (status) => {
    expect(await planOf(await worker.fetch(keyRequest(token(status)), local))).toBe("free");
  });

  it.each(["", "not a token!", "../../v3/other", "x".repeat(5000)])("ignores %j without asking Google", async (t) => {
    expect(await planOf(await worker.fetch(keyRequest(t), local))).toBe("free");
    expect(callsTo(PLAY_API)).toBe(0);
  });

  it("falls back to free when Google errors, and asks again soon", async () => {
    const t = token(503);
    expect(await planOf(await worker.fetch(keyRequest(t), local))).toBe("free");
    purchases.set(t, purchase());
    // Still within the short wait after a failure.
    expect(await planOf(await worker.fetch(keyRequest(t), local))).toBe("free");
    vi.spyOn(Date, "now").mockReturnValue(Date.now() + 31_000);
    expect(await planOf(await worker.fetch(keyRequest(t), local))).toBe("pro");
  });

  it("falls back to free when Google can't be reached", async () => {
    const t = token(purchase());
    fetchMock.mockImplementationOnce(async () => {
      throw new TypeError("network down");
    });
    expect(await planOf(await worker.fetch(keyRequest(t), local))).toBe("free");
  });

  it("falls back to free when OAuth fails", async () => {
    oauthStatus = 500;
    expect(await planOf(await worker.fetch(keyRequest(token(purchase())), local))).toBe("free");
    expect(callsTo(PLAY_API)).toBe(0);
  });

  it("ignores the header without a service account", async () => {
    const t = token(purchase());
    expect(await planOf(await worker.fetch(keyRequest(t), env))).toBe("free");
    expect(callsTo(TOKEN_URL)).toBe(0);
    expect(callsTo(PLAY_API)).toBe(0);
  });

  it("keeps the access token and Google's answer for a few minutes", async () => {
    const t = token(purchase());
    for (let i = 0; i < 3; i++) expect(await planOf(await worker.fetch(keyRequest(t), local))).toBe("pro");
    expect(callsTo(TOKEN_URL)).toBe(1);
    expect(callsTo(PLAY_API)).toBe(1);

    // Another token needs Google's answer, but not another access token.
    expect(await planOf(await worker.fetch(keyRequest(token(purchase())), local))).toBe("pro");
    expect(callsTo(TOKEN_URL)).toBe(1);
    expect(callsTo(PLAY_API)).toBe(2);

    // After a few minutes, Google is asked again, and sees the cancellation.
    purchases.set(t, purchase({ subscriptionState: "SUBSCRIPTION_STATE_EXPIRED" }));
    vi.spyOn(Date, "now").mockReturnValue(Date.now() + 6 * 60_000);
    expect(await planOf(await worker.fetch(keyRequest(t), local))).toBe("free");
    expect(callsTo(PLAY_API)).toBe(3);
  });

  it("keeps a bad token's answer too", async () => {
    const t = token();
    expect(await planOf(await worker.fetch(keyRequest(t), local))).toBe("free");
    expect(await planOf(await worker.fetch(keyRequest(t), local))).toBe("free");
    expect(callsTo(PLAY_API)).toBe(1);
  });

  it("gets a new access token when the old one expires", async () => {
    await worker.fetch(keyRequest(token(purchase())), local);
    vi.spyOn(Date, "now").mockReturnValue(Date.now() + 3600_000);
    await worker.fetch(keyRequest(token(purchase())), local);
    expect(callsTo(TOKEN_URL)).toBe(2);
  });

  it("shares one purchase's budget across installs and IPs", async () => {
    const strict = { ...local, PRO_MINUTES_PER_DAY: "4" };
    const t = token(purchase());
    expect((await worker.fetch(keyRequest(t), strict)).status).toBe(200);
    expect((await worker.fetch(keyRequest(t), strict)).status).toBe(200);
    expect((await worker.fetch(keyRequest(t), strict)).status).toBe(429);
  });
});
