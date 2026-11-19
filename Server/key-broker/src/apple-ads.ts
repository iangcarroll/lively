import type { SignedTransaction } from "./appstore";
import { overLimit } from "./auth";
import { error, hash, json, networkOf, nowSeconds, type Env } from "./broker";

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const attributionHash = (id: string) => hash("apple-ads-install:" + id.toLowerCase());

async function readToken(request: Request): Promise<string | undefined> {
  const reader = request.body?.getReader();
  if (!reader) return;
  const decoder = new TextDecoder();
  let token = "";
  while (true) {
    const { value, done } = await reader.read();
    if (done) break;
    if (value.length + token.length > 16384) {
      await reader.cancel();
      return;
    }
    token += decoder.decode(value);
  }
  return /^[A-Za-z0-9+/]+={0,2}$/.test(token) ? token : undefined;
}

interface Attribution {
  attribution?: boolean;
  campaignId?: number;
  adGroupId?: number;
  keywordId?: number;
  claimType?: string;
  conversionType?: string;
}

function validID(value: unknown): value is number {
  return typeof value === "number" && Number.isSafeInteger(value) && value > 0;
}

export async function attributeAppleAds(request: Request, env: Env, now: number): Promise<Response> {
  const id = request.headers.get("Lively-Attribution-ID") ?? "";
  const token = UUID.test(id) ? await readToken(request) : undefined;
  if (!token) return error(400, "invalid_request", "Send an installation UUID and an AdServices token.");
  const install = await attributionHash(id);
  const knownInstall = () => env.DB.prepare("SELECT 1 FROM apple_ads_installs WHERE install_hash = ?").bind(install).first();
  if (await knownInstall()) return json(200, { attributed: true });

  const ip = await hash("ip:" + networkOf(request.headers.get("CF-Connecting-IP") ?? "local"));
  const minute = Math.floor(now / 60000);
  if (await overLimit(env, [{ key: `apple-ads:ip:${ip}:${minute}`, limit: 120, resetsAt: (minute + 1) * 60000 }])) {
    return error(429, "rate_limited", "Try again later.", 60);
  }

  let record: Attribution;
  try {
    const response = await fetch("https://api-adservices.apple.com/api/v1/", {
      method: "POST", headers: { "Content-Type": "text/plain" }, body: token,
      redirect: "error", signal: AbortSignal.timeout(8000),
    });
    if (response.status === 400) return error(400, "invalid_token", "Request a new token.");
    if (response.status === 404) return error(503, "token_not_ready", "Try again later.", 5);
    if (!response.ok) throw Error("Apple Ads unavailable");
    record = await response.json<Attribution>();
    if (record.attribution === false) return json(200, { attributed: false });
    if (record.attribution !== true || !validID(record.campaignId) || !validID(record.adGroupId) ||
        (record.keywordId != null && !validID(record.keywordId))) throw Error("Incomplete record");
  } catch {
    return error(503, "attribution_unavailable", "Try again later.", 60);
  }
  // Apple's developer-mode fixture and campaigns for other apps are excluded.
  if (!env.APPLE_ADS_CAMPAIGN_IDS.split(",").includes(String(record.campaignId))) return json(200, { attributed: false });
  await env.DB.prepare(
    "INSERT INTO apple_ads_installs (install_hash, token_hash, campaign_id, ad_group_id, keyword_id, claim_type, conversion_type, received_at) " +
    "VALUES (?, ?, ?, ?, ?, ?, ?, ?) ON CONFLICT DO NOTHING",
  ).bind(install, await hash("apple-ads-token:" + token), record.campaignId, record.adGroupId, record.keywordId ?? null,
    record.claimType ?? null, record.conversionType ?? null, nowSeconds(now)).run();
  return json(200, { attributed: Boolean(await knownInstall()) });
}

/** Only an Apple-signed original purchase can bind a subscription chain to an install. */
export async function recordAppleAdsPurchase(t: SignedTransaction, env: Env): Promise<void> {
  if (t.environment !== "Production" || t.type !== "Auto-Renewable Subscription" ||
      t.inAppOwnershipType !== "PURCHASED" || t.revocationDate || !t.appAccountToken || !UUID.test(t.appAccountToken) ||
      !t.transactionId || !t.originalTransactionId || !validID(t.purchaseDate)) return;
  const initialInstall = t.transactionId === t.originalTransactionId ? await attributionHash(t.appAccountToken) : null;
  const paidAt = validID(t.price) ? nowSeconds(t.purchaseDate) : null;
  if (!initialInstall && paidAt === null) return;
  await env.DB.prepare(
    "INSERT INTO apple_ads_subscriptions (subscription_hash, original_install_hash, first_paid_at) VALUES (?1, ?2, ?3) " +
    "ON CONFLICT(subscription_hash) DO UPDATE SET " +
    "original_install_hash = coalesce(original_install_hash, excluded.original_install_hash), " +
    "first_paid_at = CASE WHEN first_paid_at IS NULL OR excluded.first_paid_at < first_paid_at THEN excluded.first_paid_at ELSE first_paid_at END",
  ).bind(await hash("apple-ads-subscription:" + t.originalTransactionId), initialInstall, paidAt).run();
}
