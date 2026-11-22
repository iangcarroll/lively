import { overLimit } from "./auth";
import { error, hash, INSTALL_ID, networkOf, type Env } from "./broker";

export const DAY_MS = 86_400_000;
export type Platform = "ios" | "macos" | "android";

async function readBatch(request: Request): Promise<unknown> {
  const reader = request.body?.getReader();
  if (!reader) return null;
  const decoder = new TextDecoder();
  let bytes = 0;
  let body = "";
  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    bytes += value.length;
    if (bytes > 4096) { await reader.cancel(); return null; }
    body += decoder.decode(value, { stream: true });
  }
  try { return JSON.parse(body + decoder.decode()); } catch { return null; }
}

function integer(value: unknown, max: number): value is number {
  return typeof value === "number" && Number.isSafeInteger(value) && value >= 0 && value <= max;
}

export async function recordAppUsage(request: Request, env: Env, now: number): Promise<Response> {
  const id = request.headers.get("Lively-Usage-ID") ?? "";
  if (!INSTALL_ID.test(id)) return error(400, "bad_usage_id", "Send an installation UUID.");
  const batch = await readBatch(request);
  if (!batch || typeof batch !== "object" || !("platform" in batch) ||
      typeof batch.platform !== "string" || !["ios", "macos", "android"].includes(batch.platform) ||
      !("days" in batch) || !Array.isArray(batch.days) || !batch.days.length || batch.days.length > 30) {
    return error(400, "invalid_request", "Send a platform and up to 30 UTC days.");
  }
  const today = Math.floor(now / DAY_MS);
  const days = [];
  for (const row of batch.days) {
    if (!row || !integer(row.day, 10_000_000) || !integer(row.opens, 86_400) ||
        !integer(row.closes, 86_400) || !integer(row.seconds, 31 * 86_400) ||
        (!row.closes && row.seconds)) return error(400, "invalid_day", "Invalid daily counters.");
    // A stale offline row or an incorrect clock must not block other days in the queue.
    if (row.day >= today - 29 && row.day <= today + 1) {
      days.push({ day: row.day, opens: row.opens, closes: row.closes, seconds: row.seconds });
    }
  }
  if (days.length) {
    const install = await hash("app-usage:" + id.toLowerCase());
    const ip = await hash("ip:" + networkOf(request.headers.get("CF-Connecting-IP") ?? "local"));
    const minute = Math.floor(now / 60_000);
    const resetsAt = (minute + 1) * 60_000;
    if (await overLimit(env, [
      { key: `app-usage:ip:${ip}:${minute}`, limit: 240, resetsAt },
      { key: `app-usage:install:${install}:${minute}`, limit: 30, resetsAt },
    ])) return error(429, "rate_limited", "Try again later.", 60);

    await env.DB.prepare(`INSERT INTO app_usage_days (day, install_hash, platform, opens, closes, seconds)
      SELECT value->>'day', ?1, ?2, value->>'opens', value->>'closes', value->>'seconds'
      FROM json_each(?3) WHERE true
      ON CONFLICT(day, platform, install_hash) DO UPDATE SET
        opens=max(opens, excluded.opens), closes=max(closes, excluded.closes), seconds=max(seconds, excluded.seconds)`)
      .bind(install, batch.platform, JSON.stringify(days)).run();
  }
  return new Response(null, { status: 204, headers: { "Cache-Control": "no-store" } });
}
