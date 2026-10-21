import { createScheduledController, env } from "cloudflare:test";
import { afterEach, beforeEach, describe, expect, it, type Mock, vi } from "vitest";
import { hash, issueSonioxKey, networkOf, REGIONS, temporaryKeyURL, type Env } from "../src/broker";
import worker from "../src/index";

const NOW = Date.UTC(2026, 9, 20, 12, 0, 30);

let soniox: Mock<typeof fetch>;

beforeEach(() => {
  soniox = vi.fn<typeof fetch>(async () =>
    Response.json({ api_key: `temp:${crypto.randomUUID()}`, expires_at: "2026-10-20T12:01:30Z" }),
  );
  vi.spyOn(globalThis, "fetch").mockImplementation(soniox);
});

afterEach(() => vi.restoreAllMocks());

/** A request from a fresh install on a fresh IP in the US, unless given. */
function keyRequest(
  installID: string = crypto.randomUUID(),
  ip = randomIP(),
  { region, country = "US" }: { region?: string; country?: string } = {},
): Request {
  const headers: Record<string, string> = { "Lively-Install-ID": installID, "CF-Connecting-IP": ip };
  if (region !== undefined) headers["Lively-Region"] = region;
  return new Request("https://broker.test/v1/soniox/key", {
    method: "POST",
    headers,
    cf: { country },
  } as RequestInit);
}

function calledURLs(): string[] {
  return soniox.mock.calls.map(([url]) => url as string);
}

function randomIP(): string {
  return `10.${Math.floor(Math.random() * 256)}.${Math.floor(Math.random() * 256)}.${Math.floor(Math.random() * 256)}`;
}

function withEnv(overrides: Partial<Env>): Env {
  return { ...env, ...overrides };
}

describe("POST /v1/soniox/key", () => {
  it("mints a single-use temporary key with the master key", async () => {
    const installID = crypto.randomUUID();
    const response = await worker.fetch(keyRequest(installID), env);

    expect(response.status).toBe(200);
    expect(response.headers.get("Cache-Control")).toBe("no-store");
    const body = await response.json<{ api_key: string; expires_at: string; expires_in_seconds: number; max_session_seconds: number }>();
    expect(body.api_key).toMatch(/^temp:/);
    expect(body.expires_at).toBe("2026-10-20T12:01:30Z");
    expect(body.max_session_seconds).toBe(7200);
    expect(body.expires_in_seconds).toBe(60);

    expect(soniox).toHaveBeenCalledOnce();
    const [url, init] = soniox.mock.calls[0] as [string, RequestInit];
    expect(url).toBe("https://api.soniox.com/v1/auth/temporary-api-key");
    expect(new Headers(init.headers).get("Authorization")).toBe("Bearer test-master-key");
    expect(JSON.parse(init.body as string)).toEqual({
      usage_type: "transcribe_websocket",
      expires_in_seconds: 60,
      single_use: true,
      max_session_duration_seconds: 7200,
      client_reference_id: await hash(`install:${installID}`),
    });
  });

  it("never returns the master key", async () => {
    const response = await worker.fetch(keyRequest(), env);
    expect(await response.text()).not.toContain("test-master-key");
  });

  it.each([undefined, "", "not-a-uuid", "../../etc"])("rejects install ID %j", async (installID) => {
    const headers: Record<string, string> = installID === undefined ? {} : { "Lively-Install-ID": installID };
    const response = await worker.fetch(
      new Request("https://broker.test/v1/soniox/key", { method: "POST", headers }),
      env,
    );
    expect(response.status).toBe(400);
    expect(soniox).not.toHaveBeenCalled();
  });

  it("treats install IDs case-insensitively", async () => {
    const id = crypto.randomUUID();
    const local = withEnv({ PER_INSTALL_KEYS_PER_MINUTE: "1" });
    expect((await issueSonioxKey(keyRequest(id.toLowerCase()), local, NOW)).status).toBe(200);
    expect((await issueSonioxKey(keyRequest(id.toUpperCase()), local, NOW)).status).toBe(429);
  });

  it("only allows POST", async () => {
    const response = await worker.fetch(new Request("https://broker.test/v1/soniox/key"), env);
    expect(response.status).toBe(405);
  });

  it("404s other paths", async () => {
    expect((await worker.fetch(new Request("https://broker.test/v1/other", { method: "POST" }), env)).status).toBe(404);
    expect((await worker.fetch(new Request("https://broker.test/healthz"), env)).status).toBe(200);
  });
});

describe("regions", () => {
  type KeyBody = { region: string; websocket_url: string; regions: Record<string, string> };

  it("uses the US project for US callers and lists every region", async () => {
    const body = await (await issueSonioxKey(keyRequest(), env, NOW)).json<KeyBody>();
    expect(body.region).toBe("us");
    expect(body.websocket_url).toBe("wss://stt-rt.soniox.com/transcribe-websocket");
    expect(body.regions).toEqual({
      us: "wss://stt-rt.soniox.com/transcribe-websocket",
      jp: "wss://stt-rt.jp.soniox.com/transcribe-websocket",
    });
    expect(calledURLs()).toEqual([temporaryKeyURL("us")]);
  });

  it.each(["JP", "TW", "SG", "CN"])("defaults callers in %s to Japan", async (country) => {
    const body = await (await issueSonioxKey(keyRequest(undefined, undefined, { country }), env, NOW)).json<KeyBody>();
    expect(body.region).toBe("jp");
    expect(body.websocket_url).toBe(REGIONS.jp.websocket);
    const [url, init] = soniox.mock.calls[0] as [string, RequestInit];
    expect(url).toBe("https://api.jp.soniox.com/v1/auth/temporary-api-key");
    expect(new Headers(init.headers).get("Authorization")).toBe("Bearer test-jp-master-key");
  });

  it("honors Lively-Region over the caller's country", async () => {
    const jp = await issueSonioxKey(keyRequest(undefined, undefined, { region: "JP", country: "US" }), env, NOW);
    expect((await jp.json<KeyBody>()).region).toBe("jp");
    const us = await issueSonioxKey(keyRequest(undefined, undefined, { region: "us", country: "JP" }), env, NOW);
    expect((await us.json<KeyBody>()).region).toBe("us");
  });

  it.each(["eu", "in", "../us", "https://evil.test"])("ignores Lively-Region %j outside the allowlist", async (region) => {
    const response = await issueSonioxKey(keyRequest(undefined, undefined, { region, country: "JP" }), env, NOW);
    expect(response.status).toBe(200);
    expect((await response.json<KeyBody>()).region).toBe("jp");
    expect(calledURLs()).toEqual([temporaryKeyURL("jp")]);
  });

  it("offers only regions with a master key", async () => {
    const local = withEnv({ SONIOX_API_KEY_JP: "" });
    const response = await issueSonioxKey(keyRequest(undefined, undefined, { region: "jp", country: "JP" }), local, NOW);
    const body = await response.json<KeyBody>();
    expect(body.region).toBe("us");
    expect(body.regions).toEqual({ us: REGIONS.us.websocket });
  });

  it("falls back to the old SONIOX_API_KEY for the US", async () => {
    const local = withEnv({ SONIOX_API_KEY_US: undefined, SONIOX_API_KEY_JP: undefined, SONIOX_API_KEY: "legacy-key" });
    const response = await issueSonioxKey(keyRequest(), local, NOW);
    expect((await response.json<KeyBody>()).region).toBe("us");
    const [, init] = soniox.mock.calls[0] as [string, RequestInit];
    expect(new Headers(init.headers).get("Authorization")).toBe("Bearer legacy-key");
  });

  it("mints in the next region when the first one fails", async () => {
    soniox.mockResolvedValueOnce(new Response("down", { status: 503 }));
    const response = await issueSonioxKey(keyRequest(undefined, undefined, { country: "JP" }), env, NOW);
    expect(response.status).toBe(200);
    expect((await response.json<KeyBody>()).region).toBe("us");
    expect(calledURLs()).toEqual([temporaryKeyURL("jp"), temporaryKeyURL("us")]);
  });

  it("returns 502 when every region fails", async () => {
    soniox.mockRejectedValue(new TypeError("network down"));
    const response = await issueSonioxKey(keyRequest(), env, NOW);
    expect(response.status).toBe(502);
    expect(calledURLs()).toHaveLength(2);
  });

  it("returns 502 without calling Soniox when no master key is set", async () => {
    const local = withEnv({ SONIOX_API_KEY_US: undefined, SONIOX_API_KEY_JP: undefined, SONIOX_API_KEY: undefined });
    expect((await issueSonioxKey(keyRequest(), local, NOW)).status).toBe(502);
    expect(soniox).not.toHaveBeenCalled();
  });

  it("never returns a master key", async () => {
    const text = await (await issueSonioxKey(keyRequest(undefined, undefined, { country: "JP" }), env, NOW)).text();
    expect(text).not.toContain("master-key");
  });
});

describe("rate limits", () => {
  it("limits keys per install per minute", async () => {
    const id = crypto.randomUUID();
    for (let i = 0; i < 6; i++) {
      expect((await issueSonioxKey(keyRequest(id), env, NOW)).status).toBe(200);
    }
    const limited = await issueSonioxKey(keyRequest(id), env, NOW);
    expect(limited.status).toBe(429);
    expect(limited.headers.get("Retry-After")).toBe("30");
    expect(soniox).toHaveBeenCalledTimes(6);

    // The next minute starts fresh.
    expect((await issueSonioxKey(keyRequest(id), env, NOW + 60_000)).status).toBe(200);
  });

  it("charges listening time per day and caps the session to what's left", async () => {
    const id = crypto.randomUUID();
    const local = withEnv({ PER_INSTALL_MINUTES_PER_DAY: "2", PER_INSTALL_KEYS_PER_MINUTE: "100" });

    const first = await issueSonioxKey(keyRequest(id), local, NOW);
    expect((await first.json<{ max_session_seconds: number }>()).max_session_seconds).toBe(120);
    const second = await issueSonioxKey(keyRequest(id), local, NOW);
    expect((await second.json<{ max_session_seconds: number }>()).max_session_seconds).toBe(70);
    const lastBody = JSON.parse((soniox.mock.calls[1] as [string, RequestInit])[1].body as string);
    expect(lastBody.max_session_duration_seconds).toBe(70);

    const third = await issueSonioxKey(keyRequest(id), local, NOW);
    expect(third.status).toBe(429);
    expect(await third.json()).toMatchObject({ error: "rate_limited", message: "Today's listening time is used up." });
    expect(Number(third.headers.get("Retry-After"))).toBe(12 * 3600 - 30);

    // Tomorrow.
    expect((await issueSonioxKey(keyRequest(id), local, NOW + 86_400_000)).status).toBe(200);
  });

  it("limits keys per IP across installs", async () => {
    const local = withEnv({ PER_IP_KEYS_PER_MINUTE: "3" });
    const ip = randomIP();
    for (let i = 0; i < 3; i++) {
      expect((await issueSonioxKey(keyRequest(undefined, ip), local, NOW)).status).toBe(200);
    }
    expect((await issueSonioxKey(keyRequest(undefined, ip), local, NOW)).status).toBe(429);
    expect((await issueSonioxKey(keyRequest(undefined, randomIP()), local, NOW)).status).toBe(200);
  });

  it("groups IPv6 clients by /64", async () => {
    const local = withEnv({ PER_IP_KEYS_PER_MINUTE: "1" });
    expect((await issueSonioxKey(keyRequest(undefined, "2001:db8:1:2::1"), local, NOW)).status).toBe(200);
    expect((await issueSonioxKey(keyRequest(undefined, "2001:db8:1:2:ffff::9"), local, NOW)).status).toBe(429);
    expect((await issueSonioxKey(keyRequest(undefined, "2001:db8:1:3::1"), local, NOW)).status).toBe(200);
  });

  it("stops everyone at the global daily cap", async () => {
    const day = Date.UTC(2026, 0, 2, 23, 59, 0);
    const local = withEnv({ GLOBAL_KEYS_PER_DAY: "2" });
    expect((await issueSonioxKey(keyRequest(), local, day)).status).toBe(200);
    expect((await issueSonioxKey(keyRequest(), local, day)).status).toBe(200);
    const capped = await issueSonioxKey(keyRequest(), local, day);
    expect(capped.status).toBe(503);
    expect(capped.headers.get("Retry-After")).toBe("60");
  });

  it("refunds a rejected request so it doesn't use up other budgets", async () => {
    const id = crypto.randomUUID();
    const local = withEnv({ PER_INSTALL_KEYS_PER_MINUTE: "1", PER_INSTALL_MINUTES_PER_DAY: "2" });
    expect((await issueSonioxKey(keyRequest(id), local, NOW)).status).toBe(200);
    for (let i = 0; i < 5; i++) {
      expect((await issueSonioxKey(keyRequest(id), local, NOW)).status).toBe(429);
    }
    // 50 s of the 120 s budget was used; the five rejections cost nothing.
    const next = await issueSonioxKey(keyRequest(id), local, NOW + 60_000);
    expect((await next.json<{ max_session_seconds: number }>()).max_session_seconds).toBe(70);
  });
});

describe("denylist", () => {
  it("blocks installs listed in DENYLIST", async () => {
    const id = crypto.randomUUID();
    const local = withEnv({ DENYLIST: ` other , ${await hash(`install:${id}`)}` });
    const response = await issueSonioxKey(keyRequest(id), local, NOW);
    expect(response.status).toBe(403);
    expect(soniox).not.toHaveBeenCalled();
  });

  it("blocks installs in the D1 denylist table", async () => {
    const id = crypto.randomUUID();
    expect((await issueSonioxKey(keyRequest(id), env, NOW)).status).toBe(200);
    await env.DB.prepare("INSERT INTO denylist (install_hash, reason) VALUES (?, ?)")
      .bind(await hash(`install:${id}`), "abuse")
      .run();
    expect((await issueSonioxKey(keyRequest(id), env, NOW)).status).toBe(403);
  });
});

describe("Soniox failures", () => {
  // One region, so a failure isn't retried elsewhere.
  const usOnly = withEnv({ SONIOX_API_KEY_JP: "" });

  it("returns 502 and refunds the charge when Soniox errors", async () => {
    const id = crypto.randomUUID();
    const local = withEnv({ PER_INSTALL_KEYS_PER_MINUTE: "1", SONIOX_API_KEY_JP: "" });
    soniox.mockResolvedValueOnce(new Response("nope", { status: 500 }));
    const failed = await issueSonioxKey(keyRequest(id), local, NOW);
    expect(failed.status).toBe(502);
    expect(await failed.text()).not.toContain("nope");
    expect((await issueSonioxKey(keyRequest(id), local, NOW)).status).toBe(200);
  });

  it("returns 502 when Soniox is unreachable", async () => {
    soniox.mockRejectedValueOnce(new TypeError("network down"));
    expect((await issueSonioxKey(keyRequest(), usOnly, NOW)).status).toBe(502);
  });

  it("returns 502 on an unexpected response shape", async () => {
    soniox.mockResolvedValueOnce(Response.json({ key: "x" }));
    expect((await issueSonioxKey(keyRequest(), usOnly, NOW)).status).toBe(502);
  });
});

describe("cleanup", () => {
  it("deletes expired counters", async () => {
    await env.DB.prepare("INSERT INTO counters (key, value, expires_at) VALUES ('old', 1, 1), ('new', 1, 9999999999)").run();
    await worker.scheduled(createScheduledController(), env);
    const { results } = await env.DB.prepare("SELECT key FROM counters WHERE key IN ('old', 'new')").all();
    expect(results).toEqual([{ key: "new" }]);
  });
});

describe("networkOf", () => {
  it.each([
    ["203.0.113.7", "203.0.113.7"],
    ["2001:db8::1", "2001:db8:0:0::/64"],
    ["2001:0DB8:0001:0002:0003:0004:0005:0006", "2001:db8:1:2::/64"],
    ["::1", "0:0:0:0::/64"],
  ])("%s → %s", (ip, network) => {
    expect(networkOf(ip)).toBe(network);
  });
});
