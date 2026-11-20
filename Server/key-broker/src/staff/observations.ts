import type { SignedTransaction } from "../appstore";
import { hash, type Env } from "../broker";
import type { SubscriptionPurchaseV2 } from "../play";

export type Store = "apple" | "play";

export const appleEvents: Record<string, string> = {
  SUBSCRIBED: "Subscribed", DID_RENEW: "Renewed", EXPIRED: "Expired",
  DID_FAIL_TO_RENEW: "Renewal failed", GRACE_PERIOD_EXPIRED: "Grace period ended",
  REFUND: "Refunded", REVOKE: "Revoked", REFUND_REVERSED: "Refund reversed",
  DID_CHANGE_RENEWAL_STATUS: "Renewal setting changed", OFFER_REDEEMED: "Offer redeemed",
  DID_CHANGE_RENEWAL_PREF: "Plan preference changed", RENEWAL_EXTENDED: "Renewal extended",
};

const playStates: Record<string, string> = {
  SUBSCRIPTION_STATE_ACTIVE: "Active", SUBSCRIPTION_STATE_PENDING: "Pending",
  SUBSCRIPTION_STATE_PAUSED: "Paused", SUBSCRIPTION_STATE_IN_GRACE_PERIOD: "In grace period",
  SUBSCRIPTION_STATE_ON_HOLD: "On hold", SUBSCRIPTION_STATE_CANCELED: "Canceled",
  SUBSCRIPTION_STATE_EXPIRED: "Expired", SUBSCRIPTION_STATE_PENDING_PURCHASE_CANCELED: "Pending purchase canceled",
};

export const referenceHash = (store: Store, reference: string) => hash(store === "apple" ? `apple-ads-subscription:${reference}` : `staff-order:play:${reference}`);

async function record(env: Env, key: string, reference: string | null, store: Store, product: string,
  event: string, observed: number, end: number | null) {
  await env.DB.prepare(`INSERT INTO subscription_observations
    (subscription_key, lookup_hash, store, product, event, observed_ms, period_end_ms)
    VALUES (?, ?, ?, ?, ?, ?, ?)
    ON CONFLICT(subscription_key) DO UPDATE SET
      lookup_hash = coalesce(excluded.lookup_hash, lookup_hash), product = excluded.product, event = excluded.event,
      observed_ms = excluded.observed_ms, period_end_ms = excluded.period_end_ms
    WHERE excluded.observed_ms > observed_ms`)
    .bind(key, reference, store, product, event, observed, end).run();
}

export async function observeApple(env: Env, t: SignedTransaction, event: string, signedAt: number) {
  if (t.environment !== "Production" || t.type !== "Auto-Renewable Subscription" ||
      !Object.hasOwn(appleEvents, event) || !Number.isSafeInteger(signedAt)) return;
  const key = await referenceHash("apple", t.originalTransactionId);
  await record(env, key, key, "apple", t.productId, appleEvents[event], signedAt, t.expiresDate ?? null);
}

export async function observePlay(env: Env, purchase: SubscriptionPurchaseV2, tokenHash: string, now: number) {
  const state = purchase.subscriptionState ?? "";
  if (purchase.testPurchase || !Object.hasOwn(playStates, state)) return;
  const products = env.PLAY_PRODUCT_IDS.split(",").map(p => p.trim());
  const items = (purchase.lineItems ?? []).filter(item => item.productId && products.includes(item.productId));
  // A subscription may contain more than one line item after a plan change.
  const item = items.sort((a, b) => (Date.parse(b.expiryTime ?? "") || 0) - (Date.parse(a.expiryTime ?? "") || 0))[0];
  if (!item?.productId) return;
  const reference = item.latestSuccessfulOrderId ?? purchase.latestOrderId;
  const lookup = reference ? await referenceHash("play", reference) : null;
  await record(env, tokenHash, lookup, "play", item.productId, playStates[state], now, Date.parse(item.expiryTime ?? "") || null);
}
