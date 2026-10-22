import { env } from "cloudflare:test";
import { describe, expect, it, vi } from "vitest";
import type { Env } from "../src/broker";
import worker from "../src/index";
import { languageName } from "../src/translate";

const STREAM =
  'data: {"model":"deepseek-flash","choices":[{"delta":{"content":"你好"}}]}\n\n' +
  'data: {"model":"deepseek-flash","choices":[{"delta":{"content":"！"}}]}\n\n' +
  "data: [DONE]\n\n";

/** An env whose AI Gateway answers with `respond`, and the spy that records its calls. */
function withGateway(respond: () => Promise<Response> = async () => new Response(STREAM), overrides: Partial<Env> = {}) {
  const run = vi.fn(respond);
  const gateway = vi.fn(() => ({ run }));
  return { env: { ...env, AI: { gateway } as unknown as Ai, DEEPSEEK_API_KEY: "test-deepseek-key", ...overrides }, run, gateway };
}

function translateRequest(body: unknown, installID: string = crypto.randomUUID(), ip = randomIP()): Request {
  return new Request("https://broker.test/v1/translate", {
    method: "POST",
    headers: { "Lively-Install-ID": installID, "CF-Connecting-IP": ip, "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
}

function randomIP(): string {
  return `10.${Math.floor(Math.random() * 256)}.${Math.floor(Math.random() * 256)}.${Math.floor(Math.random() * 256)}`;
}

const HELLO = { text: "Hello!", source: "en", target: "zh" };

describe("POST /v1/translate", () => {
  it("streams DeepSeek's translation through the gateway", async () => {
    const { env: local, run, gateway } = withGateway();
    const response = await worker.fetch(translateRequest(HELLO), local);

    expect(response.status).toBe(200);
    expect(response.headers.get("Content-Type")).toBe("text/event-stream");
    expect(response.headers.get("Lively-Plan")).toBe("free");
    expect(await response.text()).toBe(STREAM);

    expect(gateway).toHaveBeenCalledWith("default");
    const [call] = run.mock.calls[0] as unknown as [{ provider: string; endpoint: string; headers: Record<string, unknown>; query: Record<string, unknown> }];
    expect(call.provider).toBe("deepseek");
    expect(call.endpoint).toBe("chat/completions");
    expect(call.headers.Authorization).toBe("Bearer test-deepseek-key");
    expect(call.query).toMatchObject({ model: "deepseek-flash", stream: true, thinking: { type: "disabled" } });
    const messages = call.query.messages as { role: string; content: string }[];
    expect(messages[0].role).toBe("system");
    expect(messages[0].content).toContain("between English and Simplified Chinese");
    expect(messages.at(-1)).toEqual({ role: "user", content: "Hello!" });
  });

  it("sends the last three context turns as history", async () => {
    const { env: local, run } = withGateway();
    const context = [1, 2, 3, 4].map((n) => ({ source: `s${n}`, translation: `t${n}` }));
    await worker.fetch(translateRequest({ ...HELLO, context }), local);

    const messages = (run.mock.calls[0] as unknown as [{ query: { messages: { content: string }[] } }])[0].query.messages;
    expect(messages.slice(1).map((m) => m.content)).toEqual(["s2", "t2", "s3", "t3", "s4", "t4", "Hello!"]);
  });

  it("names the Chinese script asked for", async () => {
    const { env: local, run } = withGateway();
    await worker.fetch(translateRequest({ text: "你好", source: "zh", target: "en", script: "traditional" }), local);
    const messages = (run.mock.calls[0] as unknown as [{ query: { messages: { content: string }[] } }])[0].query.messages;
    expect(messages[0].content).toContain("between Traditional Chinese and English");
  });

  it.each([
    [{ ...HELLO, text: "  " }, "`text`"],
    [{ ...HELLO, source: "english" }, "`source`"],
    [{ ...HELLO, target: "en" }, "`target`"],
    [{ ...HELLO, script: "pinyin" }, "`script`"],
    [{ ...HELLO, context: [{ source: "x" }] }, "`context`"],
    [{ ...HELLO, text: "x".repeat(5000) }, "limited"],
  ])("rejects %j", async (body, message) => {
    const { env: local, run } = withGateway();
    const response = await worker.fetch(translateRequest(body), local);
    expect(response.status).toBe(400);
    expect((await response.json<{ message: string }>()).message).toContain(message);
    expect(run).not.toHaveBeenCalled();
  });

  it("needs an install ID", async () => {
    const { env: local } = withGateway();
    const request = new Request("https://broker.test/v1/translate", { method: "POST", body: JSON.stringify(HELLO) });
    expect((await worker.fetch(request, local)).status).toBe(400);
  });

  it("limits translations per install per day", async () => {
    const { env: local, run } = withGateway(undefined, { PER_INSTALL_TRANSLATIONS_PER_DAY: "2" });
    const id = crypto.randomUUID();
    for (let i = 0; i < 2; i++) expect((await worker.fetch(translateRequest(HELLO, id), local)).status).toBe(200);

    const limited = await worker.fetch(translateRequest(HELLO, id), local);
    expect(limited.status).toBe(429);
    expect(await limited.json()).toMatchObject({ error: "rate_limited", plan: "free" });
    expect(run).toHaveBeenCalledTimes(2);
  });

  it("keeps translation budgets apart from listening budgets", async () => {
    const { env: local } = withGateway(undefined, { PER_INSTALL_KEYS_PER_MINUTE: "1", PER_INSTALL_TRANSLATIONS_PER_MINUTE: "5" });
    const id = crypto.randomUUID();
    for (let i = 0; i < 3; i++) expect((await worker.fetch(translateRequest(HELLO, id), local)).status).toBe(200);
  });

  it("refunds and returns 502 when DeepSeek fails", async () => {
    const { env: local } = withGateway(async () => new Response("nope", { status: 500 }), { PER_INSTALL_TRANSLATIONS_PER_MINUTE: "1" });
    const id = crypto.randomUUID();
    expect((await worker.fetch(translateRequest(HELLO, id), local)).status).toBe(502);
    // The refund leaves the minute's one request unused.
    expect((await worker.fetch(translateRequest(HELLO, id), local)).status).toBe(502);
  });

  it("returns 502 when the gateway throws", async () => {
    const { env: local } = withGateway(async () => {
      throw new Error("down");
    });
    expect((await worker.fetch(translateRequest(HELLO), local)).status).toBe(502);
  });

  it("only allows POST", async () => {
    const { env: local } = withGateway();
    expect((await worker.fetch(new Request("https://broker.test/v1/translate"), local)).status).toBe(405);
  });
});

describe("languageName", () => {
  it("names languages in English", () => {
    expect(languageName("en")).toBe("English");
    expect(languageName("ja")).toBe("Japanese");
    expect(languageName("zh")).toBe("Simplified Chinese");
  });
});
