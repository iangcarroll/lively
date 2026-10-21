/**
 * Email sign-in with one-time codes.
 *
 *   POST /v1/auth/email/start   {email}        → 200 {ok, expires_in_seconds}
 *   POST /v1/auth/email/verify  {email, code}  → 200 {token, user: {id, email}}
 *   GET  /v1/auth/me            Authorization: Bearer <token> → 200 {user}
 *   POST /v1/auth/logout        Authorization: Bearer <token> → 200 {ok}
 *
 * Sign-in is optional. A signed-in app sends its token with key requests and
 * gets a per-account listening budget instead of the per-install one.
 *
 * Codes are 6 digits, live CODE_TTL_SECONDS and allow CODE_MAX_ATTEMPTS
 * guesses each. Codes are limited per email per hour and per day and per IP
 * per hour, so with the defaults (5 guesses, 10 codes a day) someone guessing
 * at an account has about a 1 in 20,000 chance a day.
 */

import { error, hash, json, networkOf, nowSeconds } from "./broker";
import type { Env } from "./broker";

export interface User {
  id: string;
  email: string;
}

const EMAIL = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
const CODE = /^\d{6}$/;

export async function startEmailSignIn(request: Request, env: Env, now: number): Promise<Response> {
  const body = await readJSON(request);
  const email = normalizeEmail(body?.email);
  if (!email) return error(400, "bad_email", "Enter a valid email address.");

  const limits = readAuthLimits(env);
  const hour = Math.floor(now / 3_600_000);
  const ipHash = await hash(`ip:${networkOf(request.headers.get("CF-Connecting-IP") ?? "local")}`);
  const emailHash = await hash(`email:${email}`);
  const day = Math.floor(now / 86_400_000);
  const exceeded = await overLimit(env, [
    { key: `code:email:${emailHash}:hour:${hour}`, limit: limits.codesPerEmailPerHour, resetsAt: (hour + 1) * 3_600_000 },
    { key: `code:email:${emailHash}:day:${day}`, limit: limits.codesPerEmailPerDay, resetsAt: (day + 1) * 86_400_000 },
    { key: `code:ip:${ipHash}:hour:${hour}`, limit: limits.codesPerIPPerHour, resetsAt: (hour + 1) * 3_600_000 },
  ]);
  if (exceeded) {
    return error(429, "rate_limited", "Too many codes. Try again later.", Math.max(1, Math.ceil((exceeded.resetsAt - now) / 1000)));
  }

  const code = randomCode();
  await env.DB.prepare(
    "INSERT INTO login_codes (email, code_hash, attempts, expires_at) VALUES (?1, ?2, 0, ?3) " +
      "ON CONFLICT(email) DO UPDATE SET code_hash = excluded.code_hash, attempts = 0, expires_at = excluded.expires_at",
  )
    .bind(email, await codeHash(email, code), nowSeconds(now) + limits.codeTTLSeconds)
    .run();

  try {
    await env.EMAIL.send({
      from: { email: env.EMAIL_FROM, name: "Lively" },
      to: email,
      subject: `${code} is your Lively code`,
      text: `Your Lively sign-in code is ${code}.\n\nIt expires in ${Math.round(limits.codeTTLSeconds / 60)} minutes. If you didn't ask for it, ignore this email.\n`,
    });
  } catch (e) {
    const code = (e as { code?: string }).code;
    console.error("Email send failed", code, e);
    await env.DB.prepare("DELETE FROM login_codes WHERE email = ?").bind(email).run();
    if (code === "E_VALIDATION_ERROR" || code === "E_RECIPIENT_NOT_ALLOWED" || code === "E_RECIPIENT_SUPPRESSED") {
      return error(400, "bad_email", "Lively can't send email to that address.");
    }
    return error(502, "email_failed", "Couldn't send the code. Try again.", 5);
  }

  return json(200, { ok: true, expires_in_seconds: limits.codeTTLSeconds });
}

export async function verifyEmailSignIn(request: Request, env: Env, now: number): Promise<Response> {
  const body = await readJSON(request);
  const email = normalizeEmail(body?.email);
  const code = typeof body?.code === "string" ? body.code.replace(/\s/g, "") : "";
  if (!email || !CODE.test(code)) return error(400, "bad_code", "Enter the 6-digit code from the email.");

  const limits = readAuthLimits(env);
  // Count the guess first, so concurrent guesses can't share one attempt.
  const row = await env.DB.prepare(
    "UPDATE login_codes SET attempts = attempts + 1 WHERE email = ?1 AND expires_at > ?2 RETURNING code_hash, attempts",
  )
    .bind(email, nowSeconds(now))
    .first<{ code_hash: string; attempts: number }>();
  if (!row || row.attempts > limits.codeMaxAttempts) {
    return error(400, "code_expired", "That code has expired. Ask for a new one.");
  }
  if (row.code_hash !== (await codeHash(email, code))) {
    return error(400, "wrong_code", "That code isn't right.");
  }

  const userID = crypto.randomUUID();
  const token = randomToken();
  const [, user] = await env.DB.batch<{ id: string; email: string }>([
    env.DB.prepare("DELETE FROM login_codes WHERE email = ?").bind(email),
    env.DB.prepare(
      "INSERT INTO users (id, email) VALUES (?1, ?2) ON CONFLICT(email) DO UPDATE SET email = email RETURNING id, email",
    ).bind(userID, email),
  ]);
  const account = user.results[0];
  await env.DB.prepare("INSERT INTO sessions (token_hash, user_id, expires_at) VALUES (?1, ?2, ?3)")
    .bind(await tokenHash(token), account.id, nowSeconds(now) + limits.sessionDays * 86_400)
    .run();

  return json(200, { token, user: { id: account.id, email: account.email } });
}

export async function me(request: Request, env: Env, now: number): Promise<Response> {
  const auth = await authenticate(request, env, now);
  if (auth.state !== "signed_in") return unauthorized();
  return json(200, { user: auth.user });
}

export async function logout(request: Request, env: Env): Promise<Response> {
  const token = bearerToken(request);
  if (token) await env.DB.prepare("DELETE FROM sessions WHERE token_hash = ?").bind(await tokenHash(token)).run();
  return json(200, { ok: true });
}

export type Authentication = { state: "anonymous" } | { state: "invalid" } | { state: "signed_in"; user: User };

/** No token is anonymous; a token that doesn't name a live session is invalid. */
export async function authenticate(request: Request, env: Env, now: number): Promise<Authentication> {
  const token = bearerToken(request);
  if (token === undefined) return { state: "anonymous" };
  const user = await env.DB.prepare(
    "SELECT users.id, users.email FROM sessions JOIN users ON users.id = sessions.user_id " +
      "WHERE sessions.token_hash = ?1 AND sessions.expires_at > ?2",
  )
    .bind(await tokenHash(token), nowSeconds(now))
    .first<User>();
  return user ? { state: "signed_in", user } : { state: "invalid" };
}

export function unauthorized(): Response {
  return error(401, "signed_out", "You've been signed out. Sign in again in Settings.");
}

export async function deleteExpiredAuth(env: Env, now: number): Promise<void> {
  const seconds = nowSeconds(now);
  await env.DB.batch([
    env.DB.prepare("DELETE FROM login_codes WHERE expires_at < ?").bind(seconds),
    env.DB.prepare("DELETE FROM sessions WHERE expires_at < ?").bind(seconds),
  ]);
}

function bearerToken(request: Request): string | undefined {
  const header = request.headers.get("Authorization");
  if (header === null) return undefined;
  return /^Bearer\s+(\S+)$/i.exec(header.trim())?.[1] ?? "";
}

function normalizeEmail(value: unknown): string | undefined {
  if (typeof value !== "string") return undefined;
  const email = value.trim().toLowerCase();
  return email.length <= 254 && EMAIL.test(email) ? email : undefined;
}

async function readJSON(request: Request): Promise<Record<string, unknown> | undefined> {
  try {
    const body = await request.json();
    return typeof body === "object" && body !== null ? (body as Record<string, unknown>) : undefined;
  } catch {
    return undefined;
  }
}

interface Counter {
  key: string;
  limit: number;
  /** When the window ends, in ms. */
  resetsAt: number;
}

/** Bumps each counter; if one goes over, takes them all back and returns it. */
async function overLimit(env: Env, counters: Counter[]): Promise<Counter | undefined> {
  const results = await env.DB.batch<{ value: number }>(
    counters.map((c) =>
      env.DB.prepare(
        "INSERT INTO counters (key, value, expires_at) VALUES (?1, 1, ?2) " +
          "ON CONFLICT(key) DO UPDATE SET value = value + 1 RETURNING value",
      ).bind(c.key, nowSeconds(c.resetsAt) + 3600),
    ),
  );
  const exceeded = counters.find((c, i) => (results[i].results[0]?.value ?? Number.POSITIVE_INFINITY) > c.limit);
  if (exceeded) {
    await env.DB.batch(counters.map((c) => env.DB.prepare("UPDATE counters SET value = value - 1 WHERE key = ?").bind(c.key)));
  }
  return exceeded;
}

/** Uniform over 000000–999999: rejection-samples away the modulo bias. */
function randomCode(): string {
  const buffer = new Uint32Array(1);
  const limit = Math.floor(0x1_0000_0000 / 1_000_000) * 1_000_000;
  do crypto.getRandomValues(buffer);
  while (buffer[0] >= limit);
  return String(buffer[0] % 1_000_000).padStart(6, "0");
}

/** 256 bits, base64url. */
function randomToken(): string {
  const bytes = crypto.getRandomValues(new Uint8Array(32));
  return btoa(String.fromCharCode(...bytes)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

async function codeHash(email: string, code: string): Promise<string> {
  return hash(`code:${email}:${code}`);
}

async function tokenHash(token: string): Promise<string> {
  return hash(`session:${token}`);
}

function readAuthLimits(env: Env) {
  const int = (value: string, name: string) => {
    const n = Number.parseInt(value, 10);
    if (!Number.isFinite(n) || n < 0) throw new Error(`${name} must be a non-negative integer`);
    return n;
  };
  return {
    codeTTLSeconds: int(env.CODE_TTL_SECONDS, "CODE_TTL_SECONDS"),
    codeMaxAttempts: int(env.CODE_MAX_ATTEMPTS, "CODE_MAX_ATTEMPTS"),
    codesPerEmailPerHour: int(env.CODES_PER_EMAIL_PER_HOUR, "CODES_PER_EMAIL_PER_HOUR"),
    codesPerEmailPerDay: int(env.CODES_PER_EMAIL_PER_DAY, "CODES_PER_EMAIL_PER_DAY"),
    codesPerIPPerHour: int(env.CODES_PER_IP_PER_HOUR, "CODES_PER_IP_PER_HOUR"),
    sessionDays: int(env.SESSION_DAYS, "SESSION_DAYS"),
  };
}
