/**
 * Lively key broker: hands the app short-lived, single-use Soniox keys so the
 * real key never ships in the app.
 *
 *   POST /v1/soniox/key
 *   Lively-Install-ID: <random UUID the app keeps in its Keychain>
 *   → 200 {api_key, expires_at, expires_in_seconds, max_session_seconds}
 *
 * Callers are anonymous. Abuse is bounded by per-install and per-IP limits, a
 * global daily cap and a denylist, all set in wrangler.jsonc.
 */

export interface Env {
  DB: D1Database;
  SONIOX_API_KEY: string;
  KEY_TTL_SECONDS: string;
  MAX_SESSION_SECONDS: string;
  KEY_CHARGE_SECONDS: string;
  PER_INSTALL_KEYS_PER_MINUTE: string;
  PER_INSTALL_MINUTES_PER_DAY: string;
  PER_IP_KEYS_PER_MINUTE: string;
  PER_IP_MINUTES_PER_DAY: string;
  GLOBAL_KEYS_PER_DAY: string;
  DENYLIST: string;
}

export const SONIOX_TEMPORARY_KEY_URL = "https://api.soniox.com/v1/auth/temporary-api-key";

const INSTALL_ID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;


export async function issueSonioxKey(request: Request, env: Env, now: number): Promise<Response> {
  const installID = request.headers.get("Lively-Install-ID")?.trim() ?? "";
  if (!INSTALL_ID.test(installID)) {
    return error(400, "bad_install_id", "Send a UUID in the Lively-Install-ID header.");
  }
  const installHash = await hash(`install:${installID.toLowerCase()}`);
  const ipHash = await hash(`ip:${networkOf(request.headers.get("CF-Connecting-IP") ?? "local")}`);

  if (await isDenied(env, installHash)) {
    return error(403, "denied", "This install can't get keys.");
  }

  const limits = readLimits(env);
  const minute = Math.floor(now / 60_000);
  const day = new Date(now).toISOString().slice(0, 10);
  const minuteExpiry = (minute + 2) * 60;
  const dayExpiry = nowSeconds(nextUTCMidnight(now)) + 3600;

  // Keys per minute count 1; minutes per day are tracked in charged seconds.
  const charges: Charge[] = [
    { key: `install:${installHash}:min:${minute}`, amount: 1, limit: limits.installKeysPerMinute, expiresAt: minuteExpiry, window: "minute" },
    { key: `ip:${ipHash}:min:${minute}`, amount: 1, limit: limits.ipKeysPerMinute, expiresAt: minuteExpiry, window: "minute" },
    { key: `install:${installHash}:day:${day}`, amount: limits.chargeSeconds, limit: limits.installSecondsPerDay, expiresAt: dayExpiry, window: "day" },
    { key: `ip:${ipHash}:day:${day}`, amount: limits.chargeSeconds, limit: limits.ipSecondsPerDay, expiresAt: dayExpiry, window: "day" },
    { key: `global:day:${day}`, amount: 1, limit: limits.globalKeysPerDay, expiresAt: dayExpiry, window: "global" },
  ];

  // One batch is one transaction, so concurrent requests can't both slip under a limit.
  const results = await env.DB.batch<{ value: number }>(
    charges.map((c) =>
      env.DB.prepare(
        "INSERT INTO counters (key, value, expires_at) VALUES (?1, ?2, ?3) " +
          "ON CONFLICT(key) DO UPDATE SET value = value + excluded.value RETURNING value",
      ).bind(c.key, c.amount, c.expiresAt),
    ),
  );
  const totals = results.map((r) => r.results[0]?.value ?? Number.POSITIVE_INFINITY);
  const exceeded = charges.find((c, i) => totals[i] > c.limit);
  if (exceeded) {
    await refund(env, charges);
    if (exceeded.window === "global") {
      return error(503, "capacity", "Lively has reached today's capacity. Try again later.", secondsUntil(nextUTCMidnight(now), now));
    }
    const retryAfter = exceeded.window === "minute" ? secondsUntil((minute + 1) * 60_000, now) : secondsUntil(nextUTCMidnight(now), now);
    return error(429, "rate_limited", exceeded.window === "minute" ? "Too many keys this minute." : "Today's listening time is used up.", retryAfter);
  }

  // A session may run only as long as the day's budgets have left, counting this key.
  const remaining = charges
    .map((c, i) => (c.window === "day" ? c.limit - totals[i] + c.amount : Number.POSITIVE_INFINITY))
    .reduce((a, b) => Math.min(a, b));
  const maxSession = Math.max(1, Math.min(limits.maxSessionSeconds, remaining));

  let upstream: Response;
  try {
    upstream = await fetch(SONIOX_TEMPORARY_KEY_URL, {
      method: "POST",
      headers: { Authorization: `Bearer ${env.SONIOX_API_KEY}`, "Content-Type": "application/json" },
      body: JSON.stringify({
        usage_type: "transcribe_websocket",
        expires_in_seconds: limits.keyTTLSeconds,
        single_use: true,
        max_session_duration_seconds: maxSession,
        client_reference_id: installHash,
      }),
    });
  } catch (e) {
    await refund(env, charges);
    console.error("Soniox request failed", e);
    return error(502, "upstream", "Couldn't reach Soniox.", 2);
  }

  if (!upstream.ok) {
    await refund(env, charges);
    console.error("Soniox returned", upstream.status, await upstream.text());
    return error(502, "upstream", "Soniox didn't issue a key.", 5);
  }

  const body = (await upstream.json()) as { api_key?: unknown; expires_at?: unknown };
  if (typeof body.api_key !== "string" || typeof body.expires_at !== "string") {
    await refund(env, charges);
    console.error("Unexpected Soniox response shape", Object.keys(body));
    return error(502, "upstream", "Soniox didn't issue a key.", 5);
  }

  // `expires_in_seconds` lets the app time the key by its own clock.
  return json(200, {
    api_key: body.api_key,
    expires_at: body.expires_at,
    expires_in_seconds: limits.keyTTLSeconds,
    max_session_seconds: maxSession,
  });
}

interface Charge {
  key: string;
  amount: number;
  limit: number;
  expiresAt: number;
  window: "minute" | "day" | "global";
}

async function refund(env: Env, charges: Charge[]): Promise<void> {
  await env.DB.batch(
    charges.map((c) => env.DB.prepare("UPDATE counters SET value = value - ?1 WHERE key = ?2").bind(c.amount, c.key)),
  );
}

async function isDenied(env: Env, installHash: string): Promise<boolean> {
  const listed = env.DENYLIST.split(",").map((s) => s.trim().toLowerCase());
  if (listed.includes(installHash)) return true;
  const row = await env.DB.prepare("SELECT 1 FROM denylist WHERE install_hash = ?").bind(installHash).first();
  return row !== null;
}

function readLimits(env: Env) {
  const int = (value: string, name: string) => {
    const n = Number.parseInt(value, 10);
    if (!Number.isFinite(n) || n < 0) throw new Error(`${name} must be a non-negative integer`);
    return n;
  };
  return {
    keyTTLSeconds: int(env.KEY_TTL_SECONDS, "KEY_TTL_SECONDS"),
    maxSessionSeconds: int(env.MAX_SESSION_SECONDS, "MAX_SESSION_SECONDS"),
    chargeSeconds: int(env.KEY_CHARGE_SECONDS, "KEY_CHARGE_SECONDS"),
    installKeysPerMinute: int(env.PER_INSTALL_KEYS_PER_MINUTE, "PER_INSTALL_KEYS_PER_MINUTE"),
    installSecondsPerDay: int(env.PER_INSTALL_MINUTES_PER_DAY, "PER_INSTALL_MINUTES_PER_DAY") * 60,
    ipKeysPerMinute: int(env.PER_IP_KEYS_PER_MINUTE, "PER_IP_KEYS_PER_MINUTE"),
    ipSecondsPerDay: int(env.PER_IP_MINUTES_PER_DAY, "PER_IP_MINUTES_PER_DAY") * 60,
    globalKeysPerDay: int(env.GLOBAL_KEYS_PER_DAY, "GLOBAL_KEYS_PER_DAY"),
  };
}

/** The first 128 bits of SHA-256, as hex. */
export async function hash(value: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value));
  return [...new Uint8Array(digest).slice(0, 16)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

/** IPv4 as is; IPv6 by its /64, since one device can rotate through a whole /64. */
export function networkOf(ip: string): string {
  if (!ip.includes(":")) return ip;
  const [head, tail = ""] = ip.split("::");
  const left = head ? head.split(":") : [];
  const right = tail ? tail.split(":") : [];
  const groups = ip.includes("::") ? [...left, ...Array(8 - left.length - right.length).fill("0"), ...right] : left;
  return groups.slice(0, 4).map((g) => g.toLowerCase().replace(/^0+(?=.)/, "")).join(":") + "::/64";
}

export function nowSeconds(ms: number): number {
  return Math.floor(ms / 1000);
}

function nextUTCMidnight(now: number): number {
  const d = new Date(now);
  return Date.UTC(d.getUTCFullYear(), d.getUTCMonth(), d.getUTCDate() + 1);
}

function secondsUntil(time: number, now: number): number {
  return Math.max(1, Math.ceil((time - now) / 1000));
}

export function json(status: number, body: unknown, headers: Record<string, string> = {}): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json", "Cache-Control": "no-store", ...headers },
  });
}

export function error(status: number, code: string, message: string, retryAfter?: number): Response {
  return json(status, { error: code, message }, retryAfter ? { "Retry-After": String(retryAfter) } : {});
}
