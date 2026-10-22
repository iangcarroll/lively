/**
 * Lively Pro: App Store subscriptions, checked without calling Apple.
 *
 * StoreKit 2 gives the app each transaction as a JWS signed by the App Store,
 * with its certificate chain in the `x5c` header: a leaf, Apple's Worldwide
 * Developer Relations intermediate, and Apple Root CA - G3. The app sends its
 * current Pro transaction with each key request:
 *
 *   POST /v1/soniox/key
 *   Lively-Subscription: <Transaction.jwsRepresentation>
 *
 * The broker checks the chain against its own copy of Apple's root, the
 * marker extensions Apple puts on the leaf and the intermediate (other
 * certificates under the same root, like developers' signing certificates,
 * lack them), and the signature. Then it checks the bundle ID, the product
 * and the expiry. A renewal is a new transaction, which StoreKit delivers to
 * the app, so the app always has a current one to send.
 *
 * A transaction can't be forged, but it can be copied. Pro usage is charged to
 * the subscription's original transaction ID, so a copied transaction shares
 * its owner's daily budget instead of adding to it.
 *
 * Refunds and revocations come in as App Store Server Notifications V2:
 *
 *   POST /v1/appstore/notifications   {signedPayload}   → 200 {ok}
 *
 * Those are signed the same way. A refunded or revoked subscription goes in
 * `revoked_subscriptions`, since the app may still hold an unexpired
 * transaction for it.
 */

import { X509Certificate } from "node:crypto";
import { error, json, type Env } from "./broker";

/** Apple Root CA - G3, from https://www.apple.com/certificateauthority/. SHA-256 63:34:3A:BF:…:91:79. */
const APPLE_ROOT_CA_G3 =
  "MIICQzCCAcmgAwIBAgIILcX8iNLFS5UwCgYIKoZIzj0EAwMwZzEbMBkGA1UEAwwSQXBwbGUgUm9vdCBDQSAtIEczMSYwJAYDVQQLDB1BcHBsZSBDZXJ0aWZpY2F0aW9uIEF1dGhvcml0eTETMBEGA1UECgwKQXBwbGUgSW5jLjELMAkGA1UEBhMCVVMwHhcNMTQwNDMwMTgxOTA2WhcNMzkwNDMwMTgxOTA2WjBnMRswGQYDVQQDDBJBcHBsZSBSb290IENBIC0gRzMxJjAkBgNVBAsMHUFwcGxlIENlcnRpZmljYXRpb24gQXV0aG9yaXR5MRMwEQYDVQQKDApBcHBsZSBJbmMuMQswCQYDVQQGEwJVUzB2MBAGByqGSM49AgEGBSuBBAAiA2IABJjpLz1AcqTtkyJygRMc3RCV8cWjTnHcFBbZDuWmBSp3ZHtfTjjTuxxEtX/1H7YyYl3J6YRbTzBPEVoA/VhYDKX1DyxNB0cTddqXl5dvMVztK517IDvYuVTZXpmkOlEKMaNCMEAwHQYDVR0OBBYEFLuw3qFYM4iapIqZ3r6966/ayySrMA8GA1UdEwEB/wQFMAMBAf8wDgYDVR0PAQH/BAQDAgEGMAoGCCqGSM49BAMDA2gAMGUCMQCD6cHEFl4aXTQY2e3v9GwOAEZLuN+yRhHFD/3meoyhpmvOwgPUnPWTxnS4at+qIxUCMG1mihDK1A3UT82NQz60imOlM27jbdoXt2QfyFMm+YhidDkLF1vLUagM6BgD56KyKA==";

/** DER of the extension OIDs Apple's own App Store Server Library requires. */
const LEAF_MARKER = oid(1, 2, 840, 113635, 100, 6, 11, 1);
const INTERMEDIATE_MARKER = oid(1, 2, 840, 113635, 100, 6, 2, 1);

/** The fields of a JWSTransactionDecodedPayload that the broker uses. */
export interface SignedTransaction {
  originalTransactionId: string;
  productId: string;
  bundleId: string;
  environment: string;
  type?: string;
  /** All dates are ms since the epoch. */
  signedDate: number;
  expiresDate?: number;
  revocationDate?: number;
}

/** An active Pro subscription from the request's `Lively-Subscription` header, if it has one. */
export async function proSubscription(request: Request, env: Env, now: number): Promise<SignedTransaction | undefined> {
  const jws = request.headers.get("Lively-Subscription")?.trim();
  if (!jws) return undefined;
  const transaction = await verifySignedTransaction(jws, env);
  if (!transaction) return undefined;
  if (!transaction.expiresDate || transaction.expiresDate <= now || transaction.revocationDate) return undefined;
  const revoked = await env.DB.prepare("SELECT 1 FROM revoked_subscriptions WHERE original_transaction_id = ?")
    .bind(transaction.originalTransactionId)
    .first();
  return revoked ? undefined : transaction;
}

/** A transaction signed by the App Store for one of this app's Pro products. */
export async function verifySignedTransaction(jws: string, env: Env): Promise<SignedTransaction | undefined> {
  const t = await verifyJWS<SignedTransaction>(jws, env);
  if (!t || typeof t.originalTransactionId !== "string" || typeof t.signedDate !== "number") return undefined;
  if (t.bundleId !== env.APP_BUNDLE_ID) return undefined;
  if (!list(env.PRO_PRODUCT_IDS).includes(t.productId)) return undefined;
  if (!list(env.APP_STORE_ENVIRONMENTS).includes(t.environment)) return undefined;
  return t;
}

interface NotificationPayload {
  notificationType?: string;
  signedDate?: number;
  data?: { bundleId?: string; environment?: string; signedTransactionInfo?: string };
}

export async function appStoreNotification(request: Request, env: Env): Promise<Response> {
  let signedPayload: unknown;
  try {
    signedPayload = ((await request.json()) as { signedPayload?: unknown }).signedPayload;
  } catch {
    // Handled below.
  }
  const notification = typeof signedPayload === "string" ? await verifyJWS<NotificationPayload>(signedPayload, env) : undefined;
  if (!notification) return error(400, "bad_notification", "Send a signedPayload signed by the App Store.");

  // Other apps' and environments' notifications, and types Lively ignores, are still acknowledged.
  const info = notification.data?.signedTransactionInfo;
  const transaction = info ? await verifySignedTransaction(info, env) : undefined;
  if (!transaction) return json(200, { ok: true });

  const type = notification.notificationType;
  if (type === "REFUND" || type === "REVOKE") {
    await env.DB.prepare(
      "INSERT INTO revoked_subscriptions (original_transaction_id, reason) VALUES (?1, ?2) ON CONFLICT DO NOTHING",
    )
      .bind(transaction.originalTransactionId, type)
      .run();
  } else if (type === "REFUND_REVERSED") {
    await env.DB.prepare("DELETE FROM revoked_subscriptions WHERE original_transaction_id = ?")
      .bind(transaction.originalTransactionId)
      .run();
  }
  return json(200, { ok: true });
}

/**
 * The payload of a JWS whose `x5c` chain runs from an App Store leaf through
 * an Apple intermediate to the trusted root, and whose signature the leaf made.
 * Certificates must be valid at the payload's `signedDate`, as Apple's library
 * checks them, so an old transaction stays good after its leaf expires.
 */
export async function verifyJWS<T extends { signedDate?: number }>(jws: string, env: Env): Promise<T | undefined> {
  try {
    const parts = jws.split(".");
    if (parts.length !== 3) return undefined;
    const [headerPart, payloadPart, signaturePart] = parts;
    const header = JSON.parse(utf8(base64url(headerPart))) as { alg?: unknown; x5c?: unknown };
    if (header.alg !== "ES256" || !Array.isArray(header.x5c) || header.x5c.length !== 3) return undefined;
    if (!header.x5c.every((c) => typeof c === "string")) return undefined;
    const [leaf, intermediate] = (header.x5c as string[]).slice(0, 2).map((c) => new X509Certificate(base64(c)));
    const root = env.APP_STORE_TEST_ROOT ? new X509Certificate(base64(env.APP_STORE_TEST_ROOT)) : appleRoot();

    // The chain's own root is ignored: the intermediate must verify against ours.
    if (!isAppleIntermediate(intermediate, root)) return undefined;
    if (leaf.ca || !leaf.checkIssued(intermediate) || !leaf.verify(intermediate.publicKey)) return undefined;
    if (!contains(leaf.raw, LEAF_MARKER)) return undefined;

    const key = await crypto.subtle.importKey(
      "spki",
      leaf.publicKey.export({ type: "spki", format: "der" }),
      { name: "ECDSA", namedCurve: "P-256" },
      false,
      ["verify"],
    );
    const signed = new TextEncoder().encode(`${headerPart}.${payloadPart}`);
    if (!(await crypto.subtle.verify({ name: "ECDSA", hash: "SHA-256" }, key, base64url(signaturePart), signed))) return undefined;

    const payload = JSON.parse(utf8(base64url(payloadPart))) as T;
    const signedAt = payload.signedDate;
    if (typeof signedAt !== "number" || ![leaf, intermediate, root].every((c) => validAt(c, signedAt))) return undefined;
    return payload;
  } catch {
    return undefined;
  }
}

/** A CA under `root` with the marker Apple puts on its App Store intermediates. */
export function isAppleIntermediate(intermediate: X509Certificate, root: X509Certificate = appleRoot()): boolean {
  return intermediate.ca && intermediate.checkIssued(root) && intermediate.verify(root.publicKey) && contains(intermediate.raw, INTERMEDIATE_MARKER);
}

function appleRoot(): X509Certificate {
  return new X509Certificate(base64(APPLE_ROOT_CA_G3));
}

function validAt(certificate: X509Certificate, time: number): boolean {
  const from = Date.parse(certificate.validFrom);
  const to = Date.parse(certificate.validTo);
  return from <= time && time <= to;
}

/** The DER encoding of an object identifier. */
function oid(...arcs: number[]): Uint8Array {
  const body = [40 * arcs[0] + arcs[1]];
  for (const arc of arcs.slice(2)) {
    const digits = [arc & 0x7f];
    for (let n = Math.floor(arc / 128); n > 0; n = Math.floor(n / 128)) digits.unshift((n & 0x7f) | 0x80);
    body.push(...digits);
  }
  return Uint8Array.of(0x06, body.length, ...body);
}

function contains(haystack: Uint8Array, needle: Uint8Array): boolean {
  outer: for (let i = 0; i + needle.length <= haystack.length; i++) {
    for (let j = 0; j < needle.length; j++) if (haystack[i + j] !== needle[j]) continue outer;
    return true;
  }
  return false;
}

function list(value: string): string[] {
  return value.split(",").map((s) => s.trim()).filter(Boolean);
}

function base64(value: string): Uint8Array {
  return Uint8Array.from(atob(value), (c) => c.charCodeAt(0));
}

function base64url(value: string): Uint8Array {
  const padded = value.replace(/-/g, "+").replace(/_/g, "/");
  return base64(padded + "=".repeat((4 - (padded.length % 4)) % 4));
}

function utf8(bytes: Uint8Array): string {
  return new TextDecoder().decode(bytes);
}
