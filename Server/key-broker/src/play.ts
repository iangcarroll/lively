/**
 * Lively Pro: Google Play subscriptions, checked with the Play Developer API.
 *
 * Play Billing gives the Android app a purchase token for each subscription
 * purchase. Unlike an App Store transaction, the token isn't signed data the
 * broker can check by itself, so the app sends it with each key request:
 *
 *   POST /v1/soniox/key
 *   Lively-Play-Purchase: <Purchase.getPurchaseToken()>
 *
 * and the broker asks Google about it:
 *
 *   GET https://androidpublisher.googleapis.com/androidpublisher/v3/applications/
 *       {PLAY_PACKAGE_NAME}/purchases/subscriptionsv2/tokens/{token}
 *
 * authenticating as the service account in GOOGLE_PLAY_SERVICE_ACCOUNT (its
 * JSON key file) with an RS256 JWT exchanged for an OAuth access token. The
 * access token is kept until a minute before it expires.
 *
 * A purchase is Pro while it's active, in its grace period, or cancelled but
 * paid through, and a line item for one of PRO_PRODUCT_IDS hasn't expired.
 * Google's answer is kept for a few minutes per token, so a key every few
 * minutes doesn't ask Google every time. If Google can't be reached or errors,
 * the caller just gets the plan it would have without the purchase.
 *
 * Like an App Store transaction, a token can be copied, so Pro usage is
 * charged to `play:<hash of the token>`, wherever it's used. Refunds and
 * revocations expire the subscription at Google, so the next check sees them.
 *
 * Without GOOGLE_PLAY_SERVICE_ACCOUNT, the header is ignored.
 */

import { hash, type Env } from "./broker";

const TOKEN_URL = "https://oauth2.googleapis.com/token";
const SCOPE = "https://www.googleapis.com/auth/androidpublisher";
const API = "https://androidpublisher.googleapis.com/androidpublisher/v3/applications";

/** How long Google's answer about a token is kept, and how long a failure to get one is. */
const VERIFIED_TTL_MS = 5 * 60_000;
const UNAVAILABLE_TTL_MS = 30_000;

/** Purchase tokens are opaque but URL-safe, and a few hundred characters at most. */
const PURCHASE_TOKEN = /^[A-Za-z0-9._-]{1,2048}$/;

const ENTITLED_STATES = new Set(["SUBSCRIPTION_STATE_ACTIVE", "SUBSCRIPTION_STATE_IN_GRACE_PERIOD", "SUBSCRIPTION_STATE_CANCELED"]);

/** An entitled Play subscription. `id` is what Pro usage is charged to. */
export interface PlaySubscription {
  id: string;
  productId: string;
  /** ms since the epoch. */
  expiryTime: number;
}

/** The fields of a SubscriptionPurchaseV2 that the broker uses. */
export interface SubscriptionPurchaseV2 {
  subscriptionState?: string;
  testPurchase?: object;
  lineItems?: { productId?: string; expiryTime?: string }[];
}

interface ServiceAccount {
  client_email: string;
  private_key: string;
}

/** Answers per package and token hash. `undefined` means not entitled. */
const verified = new Map<string, { subscription: PlaySubscription | undefined; until: number }>();
let accessToken: { account: string; token: string; expiresAt: number } | undefined;

/** Tests only. */
export function resetPlayCaches(): void {
  verified.clear();
  accessToken = undefined;
}

/** An entitled Pro subscription from the request's `Lively-Play-Purchase` header, if it has one. */
export async function proPlayPurchase(request: Request, env: Env, now: number): Promise<PlaySubscription | undefined> {
  if (!env.GOOGLE_PLAY_SERVICE_ACCOUNT?.trim()) return undefined;
  const token = request.headers.get("Lively-Play-Purchase")?.trim();
  if (!token || !PURCHASE_TOKEN.test(token)) return undefined;

  const tokenHash = await hash(`play:${token}`);
  const cacheKey = `${env.PLAY_PACKAGE_NAME}:${tokenHash}`;
  const cached = verified.get(cacheKey);
  if (cached && cached.until > now) return entitled(cached.subscription, now);

  const purchase = await fetchPurchase(token, env, now);
  if (purchase === "unavailable") {
    verified.set(cacheKey, { subscription: undefined, until: now + UNAVAILABLE_TTL_MS });
    return undefined;
  }
  const subscription = purchase ? proSubscriptionOf(purchase, `play:${tokenHash}`, env, now) : undefined;
  verified.set(cacheKey, { subscription, until: now + VERIFIED_TTL_MS });
  return subscription;
}

/** A cached subscription stops counting when its period ends, even before the cache does. */
function entitled(subscription: PlaySubscription | undefined, now: number): PlaySubscription | undefined {
  return subscription && subscription.expiryTime > now ? subscription : undefined;
}

/** The Pro line item of an entitled purchase, if it has one. */
export function proSubscriptionOf(purchase: SubscriptionPurchaseV2, id: string, env: Env, now: number): PlaySubscription | undefined {
  if (!ENTITLED_STATES.has(purchase.subscriptionState ?? "")) return undefined;
  if (purchase.testPurchase && env.PLAY_ALLOW_TEST_PURCHASES !== "true") return undefined;
  const products = list(env.PRO_PRODUCT_IDS);
  for (const item of purchase.lineItems ?? []) {
    const expiryTime = Date.parse(item.expiryTime ?? "");
    if (item.productId && products.includes(item.productId) && expiryTime > now) {
      return { id, productId: item.productId, expiryTime };
    }
  }
  return undefined;
}

/** Google's record of the purchase; undefined if Google says the token is bad. */
async function fetchPurchase(token: string, env: Env, now: number): Promise<SubscriptionPurchaseV2 | undefined | "unavailable"> {
  try {
    const bearer = await getAccessToken(env, now);
    if (!bearer) return "unavailable";
    const url = `${API}/${encodeURIComponent(env.PLAY_PACKAGE_NAME)}/purchases/subscriptionsv2/tokens/${encodeURIComponent(token)}`;
    const response = await fetch(url, { headers: { Authorization: `Bearer ${bearer}` } });
    if (response.ok) return (await response.json()) as SubscriptionPurchaseV2;
    if (response.status === 400 || response.status === 404 || response.status === 410) return undefined;
    // 401 means the access token went bad early; 403 means the service account lacks access in Play Console.
    if (response.status === 401) accessToken = undefined;
    console.error("Google Play returned", response.status, await response.text());
    return "unavailable";
  } catch (e) {
    console.error("Google Play request failed", e);
    return "unavailable";
  }
}

/** An OAuth access token for the service account, from the cache when it has a minute left. */
async function getAccessToken(env: Env, now: number): Promise<string | undefined> {
  const account = parseServiceAccount(env.GOOGLE_PLAY_SERVICE_ACCOUNT ?? "");
  if (!account) {
    console.error("GOOGLE_PLAY_SERVICE_ACCOUNT isn't a service account key");
    return undefined;
  }
  if (accessToken && accessToken.account === account.client_email && accessToken.expiresAt - 60_000 > now) return accessToken.token;

  const iat = Math.floor(now / 1000);
  const assertion = await signJWT({ iss: account.client_email, scope: SCOPE, aud: TOKEN_URL, iat, exp: iat + 3600 }, account.private_key);
  const response = await fetch(TOKEN_URL, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({ grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer", assertion }),
  });
  if (!response.ok) {
    console.error("Google OAuth returned", response.status, await response.text());
    return undefined;
  }
  const body = (await response.json()) as { access_token?: unknown; expires_in?: unknown };
  if (typeof body.access_token !== "string") return undefined;
  const expiresIn = typeof body.expires_in === "number" ? body.expires_in : 3600;
  accessToken = { account: account.client_email, token: body.access_token, expiresAt: now + expiresIn * 1000 };
  return accessToken.token;
}

function parseServiceAccount(value: string): ServiceAccount | undefined {
  try {
    const parsed = JSON.parse(value) as Partial<ServiceAccount>;
    if (typeof parsed.client_email !== "string" || typeof parsed.private_key !== "string") return undefined;
    return { client_email: parsed.client_email, private_key: parsed.private_key };
  } catch {
    return undefined;
  }
}

/** An RS256 JWT, signed with a PKCS #8 PEM key like the one in a service account key file. */
async function signJWT(claims: object, privateKeyPEM: string): Promise<string> {
  const der = base64(privateKeyPEM.replace(/-----(BEGIN|END) PRIVATE KEY-----/g, "").replace(/\s+/g, ""));
  const key = await crypto.subtle.importKey("pkcs8", der, { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" }, false, ["sign"]);
  const header = base64url(new TextEncoder().encode(JSON.stringify({ alg: "RS256", typ: "JWT" })));
  const payload = base64url(new TextEncoder().encode(JSON.stringify(claims)));
  const signature = await crypto.subtle.sign("RSASSA-PKCS1-v1_5", key, new TextEncoder().encode(`${header}.${payload}`));
  return `${header}.${payload}.${base64url(new Uint8Array(signature))}`;
}

function list(value: string): string[] {
  return value.split(",").map((s) => s.trim()).filter(Boolean);
}

function base64(value: string): Uint8Array {
  return Uint8Array.from(atob(value), (c) => c.charCodeAt(0));
}

function base64url(bytes: Uint8Array): string {
  return btoa(String.fromCharCode(...bytes)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}
