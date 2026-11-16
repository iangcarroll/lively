import { createScheduledController, env } from "cloudflare:test";
import { afterEach, beforeEach, describe, expect, it, type Mock, vi } from "vitest";
import { hash, issueSonioxKey, type Env } from "../src/broker";
import worker from "../src/index";

const NOW = Date.UTC(2026, 9, 20, 12, 0, 30);

let soniox: Mock<typeof fetch>;
let send: Mock<SendEmail["send"]>;
let local: Env;

beforeEach(() => {
  soniox = vi.fn<typeof fetch>(async () =>
    Response.json({ api_key: `temp:${crypto.randomUUID()}`, expires_at: "2026-10-20T12:05:30Z" }),
  );
  vi.spyOn(globalThis, "fetch").mockImplementation(soniox);
  send = vi.fn(async () => ({ messageId: crypto.randomUUID() })) as Mock<SendEmail["send"]>;
  local = { ...env, EMAIL: { send } as SendEmail };
});

afterEach(() => vi.restoreAllMocks());

function post(path: string, body: unknown, { ip = randomIP(), token }: { ip?: string; token?: string } = {}): Request {
  const headers: Record<string, string> = { "Content-Type": "application/json", "CF-Connecting-IP": ip };
  if (token !== undefined) headers.Authorization = `Bearer ${token}`;
  return new Request(`https://broker.test${path}`, { method: "POST", headers, body: JSON.stringify(body) });
}

function randomIP(): string {
  return `10.${Math.floor(Math.random() * 256)}.${Math.floor(Math.random() * 256)}.${Math.floor(Math.random() * 256)}`;
}

function randomEmail(): string {
  return `${crypto.randomUUID()}@example.com`;
}

/** The code in the last email sent. */
function sentCode(): string {
  const message = send.mock.calls.at(-1)?.[0] as EmailMessageBuilder;
  return /\b(\d{6})\b/.exec(message.subject)![1];
}

async function signIn(email = randomEmail(), envOverride: Env = local): Promise<{ token: string; user: { id: string; email: string } }> {
  expect((await worker.fetch(post("/v1/auth/email/start", { email }), envOverride)).status).toBe(200);
  const response = await worker.fetch(post("/v1/auth/email/verify", { email, code: sentCode() }), envOverride);
  expect(response.status).toBe(200);
  return response.json();
}

function keyRequest(token?: string, ip = randomIP()): Request {
  const headers: Record<string, string> = { "Lively-Install-ID": crypto.randomUUID(), "CF-Connecting-IP": ip };
  if (token !== undefined) headers.Authorization = `Bearer ${token}`;
  return new Request("https://broker.test/v1/soniox/key", { method: "POST", headers, cf: { country: "US" } } as RequestInit);
}

describe("email sign-in", () => {
  it("emails a 6-digit code and exchanges it for a session", async () => {
    const email = randomEmail();
    const start = await worker.fetch(post("/v1/auth/email/start", { email: `  ${email.toUpperCase()} ` }), local);
    expect(start.status).toBe(200);
    expect(await start.json()).toEqual({ ok: true, expires_in_seconds: 600 });

    expect(send).toHaveBeenCalledOnce();
    const message = send.mock.calls[0][0] as EmailMessageBuilder;
    expect(message.to).toBe(email);
    expect(message.from).toEqual({ email: "login@x.ian.sh", name: "Lively" });
    const code = sentCode();
    expect(message.text).toContain(code);

    const verify = await worker.fetch(post("/v1/auth/email/verify", { email, code: `${code.slice(0, 3)} ${code.slice(3)}` }), local);
    expect(verify.status).toBe(200);
    const body = await verify.json<{ token: string; user: { id: string; email: string } }>();
    expect(body.user.email).toBe(email);
    expect(body.token).toMatch(/^[A-Za-z0-9_-]{43}$/);

    const me = await worker.fetch(
      new Request("https://broker.test/v1/auth/me", { headers: { Authorization: `Bearer ${body.token}` } }),
      local,
    );
    expect(await me.json()).toEqual({ user: body.user });
  });

  it("stores neither codes nor tokens in the clear", async () => {
    const email = randomEmail();
    const { token } = await signIn(email);
    await worker.fetch(post("/v1/auth/email/start", { email }), local);
    const dump = JSON.stringify([
      (await env.DB.prepare("SELECT * FROM login_codes").all()).results,
      (await env.DB.prepare("SELECT * FROM sessions").all()).results,
    ]);
    expect(dump).not.toContain(sentCode());
    expect(dump).not.toContain(token);
  });

  it("keeps the same account across sign-ins", async () => {
    const email = randomEmail();
    const first = await signIn(email);
    const second = await signIn(email);
    expect(second.user.id).toBe(first.user.id);
    expect(second.token).not.toBe(first.token);
  });

  it.each([undefined, "", "nope", "a@b", "a b@c.com", 42])("rejects email %j", async (email) => {
    const response = await worker.fetch(post("/v1/auth/email/start", { email }), local);
    expect(response.status).toBe(400);
    expect(send).not.toHaveBeenCalled();
  });

  it("rejects a wrong code and allows only 5 guesses", async () => {
    const email = randomEmail();
    await worker.fetch(post("/v1/auth/email/start", { email }), local);
    const code = sentCode();
    const wrong = code === "000000" ? "111111" : "000000";
    for (let i = 0; i < 4; i++) {
      const response = await worker.fetch(post("/v1/auth/email/verify", { email, code: wrong }), local);
      expect(await response.json()).toMatchObject({ error: "wrong_code" });
    }
    expect((await worker.fetch(post("/v1/auth/email/verify", { email, code: wrong }), local)).status).toBe(400);
    // The right code no longer works after 5 guesses.
    const late = await worker.fetch(post("/v1/auth/email/verify", { email, code }), local);
    expect(await late.json()).toMatchObject({ error: "code_expired" });
  });

  it("uses each code once", async () => {
    const email = randomEmail();
    await worker.fetch(post("/v1/auth/email/start", { email }), local);
    const code = sentCode();
    expect((await worker.fetch(post("/v1/auth/email/verify", { email, code }), local)).status).toBe(200);
    expect((await worker.fetch(post("/v1/auth/email/verify", { email, code }), local)).status).toBe(400);
  });

  it("replaces the old code with a new one", async () => {
    const email = randomEmail();
    await worker.fetch(post("/v1/auth/email/start", { email }), local);
    const old = sentCode();
    do await worker.fetch(post("/v1/auth/email/start", { email }), local);
    while (sentCode() === old);
    expect((await worker.fetch(post("/v1/auth/email/verify", { email, code: old }), local)).status).toBe(400);
    expect((await worker.fetch(post("/v1/auth/email/verify", { email, code: sentCode() }), local)).status).toBe(200);
  });

  it("expires codes", async () => {
    const { startEmailSignIn, verifyEmailSignIn } = await import("../src/auth");
    const email = randomEmail();
    await startEmailSignIn(post("/v1/auth/email/start", { email }), local, NOW);
    const response = await verifyEmailSignIn(post("/v1/auth/email/verify", { email, code: sentCode() }), local, NOW + 601_000);
    expect(await response.json()).toMatchObject({ error: "code_expired" });
  });

  it("limits codes per email", async () => {
    const email = randomEmail();
    for (let i = 0; i < 5; i++) {
      expect((await worker.fetch(post("/v1/auth/email/start", { email }), local)).status).toBe(200);
    }
    const limited = await worker.fetch(post("/v1/auth/email/start", { email }), local);
    expect(limited.status).toBe(429);
    expect(Number(limited.headers.get("Retry-After"))).toBeGreaterThan(0);
    expect(send).toHaveBeenCalledTimes(5);
  });

  it("limits codes per IP", async () => {
    const ip = randomIP();
    const strict = { ...local, CODES_PER_IP_PER_HOUR: "2" };
    expect((await worker.fetch(post("/v1/auth/email/start", { email: randomEmail() }, { ip }), strict)).status).toBe(200);
    expect((await worker.fetch(post("/v1/auth/email/start", { email: randomEmail() }, { ip }), strict)).status).toBe(200);
    expect((await worker.fetch(post("/v1/auth/email/start", { email: randomEmail() }, { ip }), strict)).status).toBe(429);
  });

  it("reports a failed send and doesn't leave a code behind", async () => {
    const email = randomEmail();
    send.mockRejectedValueOnce(Object.assign(new Error("boom"), { code: "E_DELIVERY_FAILED" }));
    expect((await worker.fetch(post("/v1/auth/email/start", { email }), local)).status).toBe(502);
    const row = await env.DB.prepare("SELECT 1 FROM login_codes WHERE email = ?").bind(email).first();
    expect(row).toBeNull();

    send.mockRejectedValueOnce(Object.assign(new Error("suppressed"), { code: "E_RECIPIENT_SUPPRESSED" }));
    expect(await (await worker.fetch(post("/v1/auth/email/start", { email }), local)).json()).toMatchObject({ error: "bad_email" });
  });

  it("signs out", async () => {
    const { token } = await signIn();
    expect((await worker.fetch(post("/v1/auth/logout", {}, { token }), local)).status).toBe(200);
    const me = await worker.fetch(new Request("https://broker.test/v1/auth/me", { headers: { Authorization: `Bearer ${token}` } }), local);
    expect(me.status).toBe(401);
  });

  it("only routes the right methods", async () => {
    expect((await worker.fetch(new Request("https://broker.test/v1/auth/email/start"), local)).status).toBe(405);
    expect((await worker.fetch(post("/v1/auth/me", {}), local)).status).toBe(405);
    expect((await worker.fetch(post("/v1/auth/constructor", {}), local)).status).toBe(404);
  });
});

describe("signed-in keys", () => {
  it("charges the account instead of the install", async () => {
    const { token, user } = await signIn();
    const response = await worker.fetch(keyRequest(token), local);
    expect(response.status).toBe(200);
    const sent = JSON.parse((soniox.mock.calls[0] as [string, RequestInit])[1].body as string);
    expect(sent.client_reference_id).toBe(await hash(`user:${user.id}`));
    // A free account's 120 minutes a day, the most one session can run.
    expect(sent.max_session_duration_seconds).toBe(7200);
  });

  it("gives accounts their own daily budget across installs", async () => {
    const strict = { ...local, PER_USER_MINUTES_PER_DAY: "4", PER_INSTALL_MINUTES_PER_DAY: "1000" };
    const { token } = await signIn(randomEmail(), strict);
    expect((await issueSonioxKey(keyRequest(token), strict, NOW)).status).toBe(200);
    expect((await issueSonioxKey(keyRequest(token), strict, NOW)).status).toBe(200);
    expect((await issueSonioxKey(keyRequest(token), strict, NOW)).status).toBe(429);
    // Anonymous installs aren't affected.
    expect((await issueSonioxKey(keyRequest(), strict, NOW)).status).toBe(200);
  });

  it("isn't held to the per-IP daily budget", async () => {
    const ip = randomIP();
    const strict = { ...local, PER_IP_MINUTES_PER_DAY: "2" };
    expect((await issueSonioxKey(keyRequest(undefined, ip), strict, NOW)).status).toBe(200);
    expect((await issueSonioxKey(keyRequest(undefined, ip), strict, NOW)).status).toBe(429);
    const { token } = await signIn(randomEmail(), strict);
    expect((await issueSonioxKey(keyRequest(token, ip), strict, NOW)).status).toBe(200);
  });

  it("rejects a bad or signed-out token with 401", async () => {
    expect((await worker.fetch(keyRequest("not-a-token"), local)).status).toBe(401);
    const { token } = await signIn();
    await worker.fetch(post("/v1/auth/logout", {}, { token }), local);
    const response = await worker.fetch(keyRequest(token), local);
    expect(response.status).toBe(401);
    expect(await response.json()).toMatchObject({ error: "signed_out" });
    expect(soniox).not.toHaveBeenCalled();
  });

  it("denies accounts in the denylist", async () => {
    const { token, user } = await signIn();
    await env.DB.prepare("INSERT INTO denylist (install_hash, reason) VALUES (?, 'abuse')").bind(await hash(`user:${user.id}`)).run();
    expect((await worker.fetch(keyRequest(token), local)).status).toBe(403);
  });
});

describe("cleanup", () => {
  it("deletes expired codes and sessions", async () => {
    const { token, user } = await signIn();
    await env.DB.prepare("INSERT INTO login_codes (email, code_hash, expires_at) VALUES ('old@example.com', 'x', 1)").run();
    await env.DB.prepare("INSERT INTO sessions (token_hash, user_id, expires_at) VALUES ('old', ?, 1)").bind(user.id).run();
    await worker.scheduled(createScheduledController(), local);
    expect(await env.DB.prepare("SELECT 1 FROM login_codes WHERE email = 'old@example.com'").first()).toBeNull();
    expect(await env.DB.prepare("SELECT 1 FROM sessions WHERE token_hash = 'old'").first()).toBeNull();
    expect((await worker.fetch(keyRequest(token), local)).status).toBe(200);
  });
});

describe("dedicated store review sign-in", () => {
  async function configured() {
    const email = randomEmail();
    const code = String(crypto.getRandomValues(new Uint32Array(1))[0] % 1_000_000).padStart(6, "0");
    const reviewEnv = { ...local, APP_REVIEW_EMAIL: email, APP_REVIEW_CODE_HASH: await hash(`code:${email}:${code}`) };
    return { email, code, reviewEnv };
  }

  it("uses the supplied review code through the normal session and Pro flows", async () => {
    const { email, code, reviewEnv } = await configured();
    const id = crypto.randomUUID();
    await env.DB.prepare("INSERT INTO users (id, email, free_pro) VALUES (?, ?, 1)").bind(id, email).run();
    expect((await worker.fetch(post("/v1/auth/email/start", { email: ` ${email.toUpperCase()} ` }), reviewEnv)).status).toBe(200);
    expect(send).not.toHaveBeenCalled();
    const verify = await worker.fetch(post("/v1/auth/email/verify", { email, code }), reviewEnv);
    expect(verify.status).toBe(200);
    const signed = await verify.json<{ token: string; user: { id: string; free_pro: boolean } }>();
    expect(signed.user).toMatchObject({ id, free_pro: true });
    const me = await worker.fetch(new Request("https://broker.test/v1/auth/me", { headers: { Authorization: `Bearer ${signed.token}` } }), reviewEnv);
    expect(await me.json()).toEqual({ user: signed.user });
    const key = await worker.fetch(keyRequest(signed.token), reviewEnv);
    expect(key.status).toBe(200);
    expect(await key.json()).toMatchObject({ plan: "pro" });
    expect((await worker.fetch(post("/v1/auth/email/verify", { email, code }), reviewEnv)).status).toBe(400);
    expect((await worker.fetch(post("/v1/auth/logout", {}, { token: signed.token }), reviewEnv)).status).toBe(200);
    expect((await worker.fetch(keyRequest(signed.token), reviewEnv)).status).toBe(401);
    // A new challenge accepts the same reviewer credential after sign-out.
    expect((await worker.fetch(post("/v1/auth/email/start", { email }), reviewEnv)).status).toBe(200);
    expect((await worker.fetch(post("/v1/auth/email/verify", { email, code }), reviewEnv)).status).toBe(200);
  });

  it("never applies the review code or Pro grant to another address", async () => {
    const { code, reviewEnv } = await configured();
    const email = randomEmail();
    await worker.fetch(post("/v1/auth/email/start", { email }), reviewEnv);
    expect(send).toHaveBeenCalledOnce();
    // Deliberately configure a different code from the actual email challenge.
    const wrong = sentCode() === code ? (code === "000000" ? "111111" : "000000") : code;
    const isolated = { ...reviewEnv, APP_REVIEW_CODE_HASH: await hash(`code:${reviewEnv.APP_REVIEW_EMAIL}:${wrong}`) };
    expect((await worker.fetch(post("/v1/auth/email/verify", { email, code: wrong }), isolated)).status).toBe(400);
    const response = await worker.fetch(post("/v1/auth/email/verify", { email, code: sentCode() }), isolated);
    expect(await response.json()).toMatchObject({ user: { email, free_pro: false } });
  });

  it("requires a live challenge and enforces expiry and guessing limits", async () => {
    const { startEmailSignIn, verifyEmailSignIn } = await import("../src/auth");
    const { email, code, reviewEnv } = await configured();
    const verify = (value = code, now = NOW) => verifyEmailSignIn(post("/v1/auth/email/verify", { email, code: value }), reviewEnv, now);
    expect((await verify()).status).toBe(400);
    await startEmailSignIn(post("/v1/auth/email/start", { email }), reviewEnv, NOW);
    expect((await verify(code, NOW + 601_000)).status).toBe(400);
    await startEmailSignIn(post("/v1/auth/email/start", { email }), reviewEnv, NOW);
    const wrong = code === "000000" ? "111111" : "000000";
    for (let i = 0; i < Number(reviewEnv.CODE_MAX_ATTEMPTS); i++) expect((await verify(wrong)).status).toBe(400);
    expect((await verify()).status).toBe(400);
    expect(send).not.toHaveBeenCalled();
  });

  it("rate limits repeated requests for the review challenge", async () => {
    const { email, reviewEnv } = await configured();
    const limited = { ...reviewEnv, CODES_PER_EMAIL_PER_HOUR: "2" };
    for (let i = 0; i < 2; i++) expect((await worker.fetch(post("/v1/auth/email/start", { email }), limited)).status).toBe(200);
    expect((await worker.fetch(post("/v1/auth/email/start", { email }), limited)).status).toBe(429);
    expect(send).not.toHaveBeenCalled();
  });

  it.each([undefined, "", "invalid", "0".repeat(64)])("fails closed with missing or invalid review secret %j", async secret => {
    const { email, code, reviewEnv } = await configured();
    await worker.fetch(post("/v1/auth/email/start", { email }), reviewEnv);
    const disabled = { ...reviewEnv, APP_REVIEW_CODE_HASH: secret };
    expect((await worker.fetch(post("/v1/auth/email/verify", { email, code }), disabled)).status).toBe(400);
    expect((await worker.fetch(post("/v1/auth/email/start", { email }), disabled)).status).toBe(503);
    expect(send).not.toHaveBeenCalled();
  });

  it("invalidates an outstanding challenge after rotation", async () => {
    const { email, code, reviewEnv } = await configured();
    await worker.fetch(post("/v1/auth/email/start", { email }), reviewEnv);
    const replacement = code === "000000" ? "111111" : "000000";
    const rotated = { ...reviewEnv, APP_REVIEW_CODE_HASH: await hash(`code:${email}:${replacement}`) };
    expect((await worker.fetch(post("/v1/auth/email/verify", { email, code }), rotated)).status).toBe(400);
    await worker.fetch(post("/v1/auth/email/start", { email }), rotated);
    expect((await worker.fetch(post("/v1/auth/email/verify", { email, code: replacement }), rotated)).status).toBe(200);
  });

  it("allows only one concurrent redemption of a challenge", async () => {
    const { email, code, reviewEnv } = await configured();
    await worker.fetch(post("/v1/auth/email/start", { email }), reviewEnv);
    const responses = await Promise.all(Array.from({ length: 3 }, () => worker.fetch(post("/v1/auth/email/verify", { email, code }), reviewEnv)));
    expect(responses.filter(r => r.status === 200)).toHaveLength(1);
    expect(responses.filter(r => r.status === 400)).toHaveLength(2);
  });
});
