/**
 * Sign in with Apple (iOS and macOS) and Sign in with Google (Android).
 *
 *   POST /v1/auth/apple   {identity_token, nonce, authorization_code?}  → 200 {token, user}
 *   POST /v1/auth/google  {id_token, nonce}                             → 200 {token, user}
 *
 * The app gets an ID token from the system's sign-in sheet and sends it here.
 * The broker checks the token's signature against the provider's published
 * keys, then its issuer, audience (this app), expiry and nonce, and signs in
 * the account with the token's verified email: the same account an emailed
 * code for that address opens (auth.ts).
 *
 * The app makes a random `nonce` per attempt and gives the provider a hash of
 * it (Apple) or the nonce itself (Google), so a token is tied to the attempt
 * that asked for it. A token is also only accepted for TOKEN_MAX_AGE_SECONDS
 * after it was issued.
 *
 * Nothing here sends email or can be guessed at, so unlike codes these
 * endpoints have no rate limits of their own.
 *
 * Apple asks apps to revoke their access when an account is deleted. With
 * APPLE_TEAM_ID, APPLE_KEY_ID and APPLE_PRIVATE_KEY set, sign-in exchanges the
 * app's `authorization_code` for a refresh token, and deleting the account
 * revokes it.
 */

import { openSession } from "./auth";
import { error, json, type Env } from "./broker";

interface Provider {
  name: "apple" | "google";
  column: "apple_sub" | "google_sub";
  keysURL: string;
  issuers: string[];
}

const APPLE: Provider = {
  name: "apple",
  column: "apple_sub",
  keysURL: "https://appleid.apple.com/auth/keys",
  issuers: ["https://appleid.apple.com"],
};

const GOOGLE: Provider = {
  name: "google",
  column: "google_sub",
  keysURL: "https://www.googleapis.com/oauth2/v3/certs",
  issuers: ["https://accounts.google.com", "accounts.google.com"],
};

const APPLE_TOKEN_URL = "https://appleid.apple.com/auth/token";
const APPLE_REVOKE_URL = "https://appleid.apple.com/auth/revoke";

/** How long after it was issued a token can still sign in. */
const TOKEN_MAX_AGE_SECONDS = 600;
/** Allowed disagreement between the provider's clock and ours. */
const CLOCK_SKEW_SECONDS = 60;
const KEYS_TTL_MS = 3_600_000;

interface Claims {
  iss?: unknown;
  aud?: unknown;
  sub?: unknown;
  exp?: unknown;
  iat?: unknown;
  events?: unknown;
  jti?: unknown;
  nonce?: unknown;
  email?: unknown;
  email_verified?: unknown;
}

export async function appleSignIn(request: Request, env: Env, now: number): Promise<Response> {
  const body = await readJSON(request);
  const nonce = text(body?.nonce);
  const claims = await verifyIDToken(text(body?.identity_token), APPLE, list(env.APP_BUNDLE_ID), now);
  // Apple puts the SHA-256 of the app's nonce in the token.
  if (!claims || !nonce || claims.nonce !== (await sha256Hex(nonce))) return rejected();
  const response = await signIn(env, now, APPLE, claims);
  if (response.status === 200) {
    await env.DB.prepare("UPDATE users SET apple_authorized_at = MAX(apple_authorized_at, ?) WHERE apple_sub = ?")
      .bind(Number(claims.iat) * 1000, claims.sub).run();
    await keepAppleRefreshToken(env, now, claims.sub as string, text(body?.authorization_code));
  }
  return response;
}

export async function googleSignIn(request: Request, env: Env, now: number): Promise<Response> {
  const audiences = list(env.GOOGLE_CLIENT_ID);
  if (audiences.length === 0) return error(503, "unavailable", "Google sign-in isn't available right now.");
  const body = await readJSON(request);
  const nonce = text(body?.nonce);
  const claims = await verifyIDToken(text(body?.id_token), GOOGLE, audiences, now);
  if (!claims || !nonce || claims.nonce !== nonce) return rejected();
  return signIn(env, now, GOOGLE, claims);
}

function rejected(): Response {
  return error(400, "bad_token", "Couldn't sign you in. Try again.");
}

/** Opens a session for the account the verified token names, creating or linking it by email. */
async function signIn(env: Env, now: number, provider: Provider, claims: Claims): Promise<Response> {
  const sub = claims.sub as string;
  const known = await env.DB.prepare(`SELECT id FROM users WHERE ${provider.column} = ?`).bind(sub).first<{ id: string }>();
  if (known) return openSession(env, now, known.id);

  // Both providers send booleans, but Apple once sent the string "true".
  const verified = claims.email_verified === true || claims.email_verified === "true";
  const email = typeof claims.email === "string" ? claims.email.trim().toLowerCase() : "";
  if (!verified || !email || email.length > 254) {
    return error(400, "no_email", "That account didn't share a verified email. Sign in with an emailed code instead.");
  }
  // The provider vouches for the address, as an emailed code would, so an
  // existing account with it is this person's.
  const user = await env.DB.prepare(
    `INSERT INTO users (id, email, ${provider.column}) VALUES (?1, ?2, ?3) ` +
      `ON CONFLICT(email) DO UPDATE SET ${provider.column} = excluded.${provider.column} RETURNING id`,
  ).bind(crypto.randomUUID(), email, sub).first<{ id: string }>();
  if (!user) throw new Error("Sign-in did not return an account");
  return openSession(env, now, user.id);
}

/** The token's claims, if one of the provider's keys signed it for one of `audiences` recently. */
export async function verifyIDToken(token: string | undefined, provider: Provider, audiences: string[], now: number): Promise<Claims | undefined> {
  const claims = await verifyProviderPayload(token, provider, audiences, now);
  const seconds = Math.floor(now / 1000);
  if (!claims || typeof claims.sub !== "string" || !claims.sub || claims.sub.length > 255) return undefined;
  if (typeof claims.exp !== "number" || claims.exp + CLOCK_SKEW_SECONDS < seconds) return undefined;
  if (typeof claims.iat !== "number" || claims.iat + TOKEN_MAX_AGE_SECONDS < seconds) return undefined;
  return claims;
}

/** Both identity tokens and account-change events use Apple's published signing keys. */
async function verifyProviderPayload(token: string | undefined, provider: Provider, audiences: string[], now: number): Promise<Claims | undefined> {
  const parts = token?.split(".") ?? [];
  if (parts.length !== 3) return undefined;
  let header: { alg?: unknown; kid?: unknown };
  let claims: Claims;
  try {
    header = JSON.parse(utf8(base64url(parts[0])));
    claims = JSON.parse(utf8(base64url(parts[1])));
  } catch {
    return undefined;
  }
  if (!header || !claims || header.alg !== "RS256" || typeof header.kid !== "string") return undefined;
  const key = await signingKey(provider, header.kid, now);
  if (!key) return undefined;
  let signed = false;
  try {
    signed = await crypto.subtle.verify("RSASSA-PKCS1-v1_5", key, base64url(parts[2]), new TextEncoder().encode(`${parts[0]}.${parts[1]}`));
  } catch {
    return undefined;
  }
  if (!signed) return undefined;

  const seconds = Math.floor(now / 1000);
  if (typeof claims.iss !== "string" || !provider.issuers.includes(claims.iss)) return undefined;
  if (typeof claims.aud !== "string" || !audiences.includes(claims.aud)) return undefined;
  if (typeof claims.iat !== "number" || claims.iat - CLOCK_SKEW_SECONDS > seconds) return undefined;
  return claims;
}

/** Account changes sent to the primary App ID, separate from StoreKit notifications. */
export async function appleAccountNotification(request: Request, env: Env, now: number): Promise<Response> {
  const body = await readJSON(request);
  const claims = await verifyProviderPayload(text(body?.payload), APPLE, list(env.APP_BUNDLE_ID), now);
  if (!claims || !text(claims.jti)) return error(400, "bad_notification", "Expected an Apple account notification.");
  let event = claims.events;
  if (typeof event === "string") {
    try { event = JSON.parse(event); } catch { event = null; }
  }
  if (!event || typeof event !== "object") return error(400, "bad_notification", "Missing event.");
  const { sub, type, event_time: timestamp, email } = event as Record<string, unknown>;
  if (typeof sub !== "string" || !sub || sub.length > 255 || typeof type !== "string"
    || typeof timestamp !== "number" || !Number.isSafeInteger(timestamp) || timestamp <= 0) {
    return error(400, "bad_notification", "Invalid event.");
  }
  const at = timestamp < 1e12 ? timestamp * 1000 : timestamp;
  if (at > now + CLOCK_SKEW_SECONDS * 1000) return error(400, "bad_notification", "Invalid event date.");
  if (type === "email-enabled" || type === "email-disabled") {
    if (typeof email === "string" && email.toLowerCase().endsWith("@privaterelay.appleid.com")) {
      await env.DB.prepare("UPDATE users SET apple_email_disabled = ?, apple_email_event_at = ? WHERE apple_sub = ? AND email = ? AND apple_email_event_at < ?")
        .bind(type === "email-disabled" ? 1 : 0, at, sub, email.toLowerCase(), at).run();
    }
  } else if (type === "consent-revoked" || type === "account-deleted") {
    // Apply once to the grant that existed when Apple issued the event. A delayed
    // delivery must not end a newer grant. Sessions cascade when the user is deleted.
    const affected = "SELECT id FROM users WHERE apple_sub = ? AND apple_authorized_at <= ?";
    const address = "SELECT email FROM users WHERE apple_sub = ? AND apple_authorized_at <= ?";
    const change = type === "account-deleted"
      ? "DELETE FROM users WHERE apple_sub = ? AND apple_authorized_at <= ?"
      : "UPDATE users SET apple_sub = NULL, apple_refresh_token = NULL, apple_email_disabled = 0, " +
        "apple_email_event_at = MAX(apple_email_event_at, ?2) WHERE apple_sub = ?1 AND apple_authorized_at <= ?2";
    await env.DB.batch([
      env.DB.prepare(`DELETE FROM sessions WHERE user_id IN (${affected})`).bind(sub, at),
      env.DB.prepare(`DELETE FROM login_codes WHERE email IN (${address})`).bind(sub, at),
      env.DB.prepare(change).bind(sub, at),
    ]);
  }
  return json(200, { ok: true });
}

interface JWK extends JsonWebKey {
  kid?: string;
}

const keySets = new Map<string, { keys: JWK[]; fetchedAt: number }>();

/** Tests only. */
export function resetIdentityCaches(): void {
  keySets.clear();
}

/** The provider's key `kid`, from its published set. An unknown `kid` refetches the set, at most once a minute. */
async function signingKey(provider: Provider, kid: string, now: number): Promise<CryptoKey | undefined> {
  let set = keySets.get(provider.keysURL);
  const stale = !set || now - set.fetchedAt > KEYS_TTL_MS;
  const missing = set && !set.keys.some((k) => k.kid === kid) && now - set.fetchedAt > 60_000;
  if (stale || missing) {
    try {
      const response = await fetch(provider.keysURL);
      if (response.ok) {
        const body = (await response.json()) as { keys?: JWK[] };
        if (Array.isArray(body.keys)) {
          set = { keys: body.keys, fetchedAt: now };
          keySets.set(provider.keysURL, set);
        }
      } else {
        console.error(`${provider.name} keys returned`, response.status);
      }
    } catch (e) {
      console.error(`${provider.name} keys request failed`, e);
    }
  }
  const jwk = set?.keys.find((k) => k.kid === kid && k.kty === "RSA");
  if (!jwk) return undefined;
  try {
    return await crypto.subtle.importKey("jwk", { kty: "RSA", n: jwk.n, e: jwk.e }, { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" }, false, ["verify"]);
  } catch {
    return undefined;
  }
}

// MARK: Revoking Apple's grant

/** Trades the app's authorization code for a refresh token and keeps it. Never fails the sign-in. */
async function keepAppleRefreshToken(env: Env, now: number, sub: string, code: string | undefined): Promise<void> {
  if (!code) return;
  try {
    const secret = await appleClientSecret(env, now);
    if (!secret) return;
    const response = await fetch(APPLE_TOKEN_URL, {
      method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams({ client_id: primaryBundleID(env), client_secret: secret, code, grant_type: "authorization_code" }),
    });
    if (!response.ok) {
      console.error("Apple token exchange returned", response.status, await response.text());
      return;
    }
    const body = (await response.json()) as { refresh_token?: unknown };
    if (typeof body.refresh_token !== "string") return;
    await env.DB.prepare("UPDATE users SET apple_refresh_token = ?1 WHERE apple_sub = ?2").bind(body.refresh_token, sub).run();
  } catch (e) {
    console.error("Apple token exchange failed", e);
  }
}

/** Ends the app's access to the Apple Account, as Apple asks when an account is deleted. Never fails the deletion. */
export async function revokeAppleGrant(env: Env, now: number, userID: string): Promise<void> {
  try {
    const row = await env.DB.prepare("SELECT apple_refresh_token FROM users WHERE id = ?").bind(userID).first<{ apple_refresh_token: string | null }>();
    if (!row?.apple_refresh_token) return;
    const secret = await appleClientSecret(env, now);
    if (!secret) return;
    const response = await fetch(APPLE_REVOKE_URL, {
      method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams({
        client_id: primaryBundleID(env),
        client_secret: secret,
        token: row.apple_refresh_token,
        token_type_hint: "refresh_token",
      }),
    });
    if (!response.ok) console.error("Apple revoke returned", response.status, await response.text());
  } catch (e) {
    console.error("Apple revoke failed", e);
  }
}

/** An ES256 JWT that names this app to Apple's token endpoints; undefined without the key. */
async function appleClientSecret(env: Env, now: number): Promise<string | undefined> {
  const pem = env.APPLE_PRIVATE_KEY?.trim();
  if (!pem || !env.APPLE_TEAM_ID || !env.APPLE_KEY_ID) return undefined;
  const der = Uint8Array.from(atob(pem.replace(/-----(BEGIN|END) PRIVATE KEY-----/g, "").replace(/\s+/g, "")), (c) => c.charCodeAt(0));
  const key = await crypto.subtle.importKey("pkcs8", der, { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"]);
  const iat = Math.floor(now / 1000);
  const encode = (value: object) => toBase64url(new TextEncoder().encode(JSON.stringify(value)));
  const signing = `${encode({ alg: "ES256", kid: env.APPLE_KEY_ID })}.${encode({
    iss: env.APPLE_TEAM_ID,
    iat,
    exp: iat + 300,
    aud: "https://appleid.apple.com",
    sub: primaryBundleID(env),
  })}`;
  const signature = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, key, new TextEncoder().encode(signing));
  return `${signing}.${toBase64url(new Uint8Array(signature))}`;
}

function primaryBundleID(env: Env): string {
  return list(env.APP_BUNDLE_ID)[0] ?? "";
}

// MARK: Helpers

async function readJSON(request: Request): Promise<Record<string, unknown> | undefined> {
  try {
    const body = await request.json();
    return typeof body === "object" && body !== null ? (body as Record<string, unknown>) : undefined;
  } catch {
    return undefined;
  }
}

function text(value: unknown): string | undefined {
  return typeof value === "string" && value !== "" && value.length <= 8192 ? value : undefined;
}

function list(value: string | undefined): string[] {
  return (value ?? "").split(",").map((s) => s.trim()).filter(Boolean);
}

async function sha256Hex(value: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value));
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

function base64url(value: string): Uint8Array {
  return Uint8Array.from(atob(value.replace(/-/g, "+").replace(/_/g, "/")), (c) => c.charCodeAt(0));
}

function toBase64url(bytes: Uint8Array): string {
  return btoa(String.fromCharCode(...bytes)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function utf8(bytes: Uint8Array): string {
  return new TextDecoder().decode(bytes);
}
