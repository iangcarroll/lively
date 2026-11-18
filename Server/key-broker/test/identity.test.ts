import { env } from "cloudflare:test";
import { afterEach, beforeEach, describe, expect, it, type Mock, vi } from "vitest";
import type { Env } from "../src/broker";
import { resetIdentityCaches } from "../src/identity";
import worker from "../src/index";

const NOW = Date.UTC(2026, 10, 17, 12, 0, 0);
const GOOGLE_CLIENT = "1234-test.apps.googleusercontent.com";
const APPLE_KEYS = "https://appleid.apple.com/auth/keys";
const GOOGLE_KEYS = "https://www.googleapis.com/oauth2/v3/certs";

let provider: CryptoKeyPair;
let stranger: CryptoKeyPair;
let jwk: JsonWebKey;
let outbound: Mock<typeof fetch>;
let send: Mock<SendEmail["send"]>;
let local: Env;

beforeEach(async () => {
  const algorithm = { name: "RSASSA-PKCS1-v1_5", modulusLength: 2048, publicExponent: new Uint8Array([1, 0, 1]), hash: "SHA-256" };
  provider ??= (await crypto.subtle.generateKey(algorithm, true, ["sign", "verify"])) as CryptoKeyPair;
  stranger ??= (await crypto.subtle.generateKey(algorithm, true, ["sign", "verify"])) as CryptoKeyPair;
  jwk = (await crypto.subtle.exportKey("jwk", provider.publicKey)) as JsonWebKey;
  resetIdentityCaches();
  outbound = vi.fn<typeof fetch>(async (input) => {
    const url = String(input instanceof Request ? input.url : input);
    if (url === APPLE_KEYS || url === GOOGLE_KEYS) return Response.json({ keys: [{ ...jwk, kid: "k1", alg: "RS256", use: "sig" }] });
    if (url === "https://appleid.apple.com/auth/token") return Response.json({ refresh_token: "apple-refresh" });
    if (url === "https://appleid.apple.com/auth/revoke") return new Response(null, { status: 200 });
    return new Response("unexpected", { status: 500 });
  });
  vi.spyOn(globalThis, "fetch").mockImplementation(outbound);
  vi.spyOn(Date, "now").mockReturnValue(NOW);
  send = vi.fn(async () => ({ messageId: crypto.randomUUID() })) as Mock<SendEmail["send"]>;
  local = { ...env, EMAIL: { send } as SendEmail, GOOGLE_CLIENT_ID: GOOGLE_CLIENT };
});

afterEach(() => vi.restoreAllMocks());

function b64(value: object | Uint8Array): string {
  const bytes = value instanceof Uint8Array ? value : new TextEncoder().encode(JSON.stringify(value));
  return btoa(String.fromCharCode(...bytes)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

async function sign(claims: object, key: CryptoKey = provider.privateKey, header: object = { alg: "RS256", kid: "k1" }): Promise<string> {
  const signing = `${b64(header)}.${b64(claims)}`;
  const signature = await crypto.subtle.sign("RSASSA-PKCS1-v1_5", key, new TextEncoder().encode(signing));
  return `${signing}.${b64(new Uint8Array(signature))}`;
}

async function sha256Hex(value: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value));
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

function post(path: string, body: unknown, token?: string): Request {
  const headers: Record<string, string> = { "Content-Type": "application/json", "CF-Connecting-IP": "10.9.8.7" };
  if (token) headers.Authorization = `Bearer ${token}`;
  return new Request(`https://broker.test${path}`, { method: "POST", headers, body: JSON.stringify(body) });
}

function randomEmail(): string {
  return `${crypto.randomUUID()}@example.com`;
}

const seconds = Math.floor(NOW / 1000);

async function appleClaims(overrides: Record<string, unknown> = {}, nonce = "raw-nonce") {
  return {
    iss: "https://appleid.apple.com",
    aud: env.APP_BUNDLE_ID,
    sub: `apple.${crypto.randomUUID()}`,
    iat: seconds - 5,
    exp: seconds + 86_400,
    nonce: await sha256Hex(nonce),
    email: randomEmail(),
    email_verified: true,
    ...overrides,
  };
}

function googleClaims(overrides: Record<string, unknown> = {}) {
  return {
    iss: "https://accounts.google.com",
    aud: GOOGLE_CLIENT,
    sub: String(Math.floor(Math.random() * 1e15)),
    iat: seconds - 5,
    exp: seconds + 3600,
    nonce: "raw-nonce",
    email: randomEmail(),
    email_verified: true,
    ...overrides,
  };
}

type SignedIn = { token: string; user: { id: string; email: string; free_pro: boolean } };

async function apple(claims: object, extra: object = {}, envOverride: Env = local): Promise<Response> {
  return worker.fetch(post("/v1/auth/apple", { identity_token: await sign(claims), nonce: "raw-nonce", ...extra }), envOverride);
}

async function google(claims: object, envOverride: Env = local): Promise<Response> {
  return worker.fetch(post("/v1/auth/google", { id_token: await sign(claims), nonce: "raw-nonce" }), envOverride);
}

describe("Sign in with Apple", () => {
  it("opens a session for the token's email", async () => {
    const claims = await appleClaims({ email: "Someone@Example.com" });
    const response = await apple(claims);
    expect(response.status).toBe(200);
    const body = await response.json<SignedIn>();
    expect(body.user.email).toBe("someone@example.com");
    expect(body.user.free_pro).toBe(false);

    const me = await worker.fetch(new Request("https://broker.test/v1/auth/me", { headers: { Authorization: `Bearer ${body.token}` } }), local);
    expect(await me.json()).toEqual({ user: body.user });
  });

  it("finds the account again by Apple's ID, whatever email the token carries", async () => {
    const claims = await appleClaims();
    const first = await (await apple(claims)).json<SignedIn>();
    const again = await (await apple({ ...claims, email: undefined, email_verified: undefined })).json<SignedIn>();
    expect(again.user).toEqual(first.user);
    const moved = await (await apple({ ...claims, email: randomEmail() })).json<SignedIn>();
    expect(moved.user).toEqual(first.user);
  });

  it("opens the account an emailed code made for the same address", async () => {
    const email = randomEmail();
    await worker.fetch(post("/v1/auth/email/start", { email }), local);
    const code = /\b(\d{6})\b/.exec((send.mock.calls.at(-1)![0] as EmailMessageBuilder).subject)![1];
    const byCode = await (await worker.fetch(post("/v1/auth/email/verify", { email, code }), local)).json<SignedIn>();
    const byApple = await (await apple(await appleClaims({ email }))).json<SignedIn>();
    expect(byApple.user.id).toBe(byCode.user.id);
  });

  it("accepts Apple's string form of email_verified, and refuses an unverified or missing email", async () => {
    expect((await apple(await appleClaims({ email_verified: "true" }))).status).toBe(200);
    for (const overrides of [{ email_verified: false }, { email_verified: undefined }, { email: undefined }]) {
      const response = await apple(await appleClaims(overrides));
      expect(response.status).toBe(400);
      expect(await response.json()).toMatchObject({ error: "no_email" });
    }
  });

  it.each([
    ["another app's token", { aud: "com.example.other" }],
    ["another issuer", { iss: "https://accounts.google.com" }],
    ["an expired token", { exp: seconds - 120 }],
    ["an old token", { iat: seconds - 3600 }],
    ["a token from the future", { iat: seconds + 3600 }],
    ["another attempt's nonce", { nonce: "0".repeat(64) }],
    ["no subject", { sub: "" }],
  ])("rejects %s", async (_name, overrides) => {
    const response = await apple(await appleClaims(overrides));
    expect(response.status).toBe(400);
    expect(await response.json()).toMatchObject({ error: "bad_token" });
  });

  it("rejects tokens Apple didn't sign", async () => {
    const claims = await appleClaims();
    const forged = await sign(claims, stranger.privateKey);
    const unknownKey = await sign(claims, provider.privateKey, { alg: "RS256", kid: "other" });
    const unsigned = `${b64({ alg: "none", kid: "k1" })}.${b64(claims)}.`;
    const [h, , s] = (await sign(claims)).split(".");
    const swapped = `${h}.${b64({ ...claims, email: "victim@example.com" })}.${s}`;
    for (const identity_token of [forged, unknownKey, unsigned, swapped, "nope", "", undefined, 42]) {
      const response = await worker.fetch(post("/v1/auth/apple", { identity_token, nonce: "raw-nonce" }), local);
      expect(response.status).toBe(400);
    }
    expect((await worker.fetch(post("/v1/auth/apple", { identity_token: await sign(claims) }), local)).status).toBe(400);
  });

  it("fetches Apple's keys once and reuses them", async () => {
    await apple(await appleClaims());
    await apple(await appleClaims());
    expect(outbound.mock.calls.filter(([input]) => String(input) === APPLE_KEYS)).toHaveLength(1);
  });

  it("turns tokens away while Apple's keys can't be fetched", async () => {
    outbound.mockImplementation(async () => new Response("down", { status: 503 }));
    expect((await apple(await appleClaims())).status).toBe(400);
  });
});

describe("revoking Apple's grant", () => {
  async function withAppleKey(): Promise<Env> {
    const pair = (await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"])) as CryptoKeyPair;
    const der = new Uint8Array((await crypto.subtle.exportKey("pkcs8", pair.privateKey)) as ArrayBuffer);
    const pem = `-----BEGIN PRIVATE KEY-----\n${btoa(String.fromCharCode(...der))}\n-----END PRIVATE KEY-----`;
    return { ...local, APPLE_TEAM_ID: "TEAM123456", APPLE_KEY_ID: "KEY1234567", APPLE_PRIVATE_KEY: pem };
  }

  function calls(url: string): URLSearchParams[] {
    return outbound.mock.calls.filter(([input]) => String(input) === url).map(([, init]) => init!.body as URLSearchParams);
  }

  it("keeps a refresh token at sign-in and revokes it when the account is deleted", async () => {
    const configured = await withAppleKey();
    const { token } = await (await apple(await appleClaims(), { authorization_code: "auth-code" }, configured)).json<SignedIn>();
    const exchange = calls("https://appleid.apple.com/auth/token");
    expect(exchange).toHaveLength(1);
    expect(exchange[0].get("code")).toBe("auth-code");
    expect(exchange[0].get("client_id")).toBe(env.APP_BUNDLE_ID);
    const [header, payload] = exchange[0].get("client_secret")!.split(".").slice(0, 2).map((part) => JSON.parse(atob(part.replace(/-/g, "+").replace(/_/g, "/"))));
    expect(header).toEqual({ alg: "ES256", kid: "KEY1234567" });
    expect(payload).toMatchObject({ iss: "TEAM123456", sub: env.APP_BUNDLE_ID, aud: "https://appleid.apple.com" });

    expect((await worker.fetch(post("/v1/auth/delete", {}, token), configured)).status).toBe(200);
    const revoke = calls("https://appleid.apple.com/auth/revoke");
    expect(revoke).toHaveLength(1);
    expect(revoke[0].get("token")).toBe("apple-refresh");
    expect((await env.DB.prepare("SELECT COUNT(*) AS n FROM users WHERE apple_refresh_token = 'apple-refresh'").first<{ n: number }>())!.n).toBe(0);
  });

  it("signs in and deletes without the key, and when Apple's endpoints fail", async () => {
    const plain = await (await apple(await appleClaims(), { authorization_code: "auth-code" })).json<SignedIn>();
    expect(calls("https://appleid.apple.com/auth/token")).toHaveLength(0);
    expect((await worker.fetch(post("/v1/auth/delete", {}, plain.token), local)).status).toBe(200);

    const configured = await withAppleKey();
    const claims = await appleClaims();
    const kept = await (await apple(claims, { authorization_code: "auth-code" }, configured)).json<SignedIn>();
    outbound.mockImplementation(async () => new Response("down", { status: 500 }));
    expect((await worker.fetch(post("/v1/auth/delete", {}, kept.token), configured)).status).toBe(200);
    expect((await worker.fetch(new Request("https://broker.test/v1/auth/me", { headers: { Authorization: `Bearer ${kept.token}` } }), configured)).status).toBe(401);
  });
});

describe("Sign in with Google", () => {
  it("opens a session, and the same account as Apple or a code for that email", async () => {
    const email = randomEmail();
    const claims = googleClaims({ email });
    const first = await google(claims);
    expect(first.status).toBe(200);
    const body = await first.json<SignedIn>();
    expect(body.user.email).toBe(email);
    expect((await (await google({ ...claims, email: randomEmail() })).json<SignedIn>()).user).toEqual(body.user);
    expect((await (await apple(await appleClaims({ email }))).json<SignedIn>()).user.id).toBe(body.user.id);
  });

  it("accepts both of Google's issuer spellings", async () => {
    expect((await google(googleClaims({ iss: "accounts.google.com" }))).status).toBe(200);
  });

  it.each([
    ["another client's token", { aud: "other.apps.googleusercontent.com" }],
    ["Apple's issuer", { iss: "https://appleid.apple.com" }],
    ["another attempt's nonce", { nonce: "other" }],
    ["an expired token", { exp: seconds - 120 }],
  ])("rejects %s", async (_name, overrides) => {
    const response = await google(googleClaims(overrides));
    expect(response.status).toBe(400);
    expect(await response.json()).toMatchObject({ error: "bad_token" });
  });

  it("refuses an unverified email", async () => {
    expect(await (await google(googleClaims({ email_verified: false }))).json()).toMatchObject({ error: "no_email" });
  });

  it("is off without a client ID", async () => {
    const response = await google(googleClaims(), { ...local, GOOGLE_CLIENT_ID: "" });
    expect(response.status).toBe(503);
  });

  it("doesn't take an Apple token, or Apple a Google one", async () => {
    const appleToken = await sign(await appleClaims({ nonce: "raw-nonce" }));
    expect((await worker.fetch(post("/v1/auth/google", { id_token: appleToken, nonce: "raw-nonce" }), local)).status).toBe(400);
    const googleToken = await sign(googleClaims({ nonce: await sha256Hex("raw-nonce") }));
    expect((await worker.fetch(post("/v1/auth/apple", { identity_token: googleToken, nonce: "raw-nonce" }), local)).status).toBe(400);
  });
});
