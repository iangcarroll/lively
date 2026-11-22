import { env } from "cloudflare:test";
import { afterEach, beforeEach, expect, it, vi } from "vitest";
import broker from "../src/index";
import { DAY_MS } from "../src/app-usage";

const now = Date.now();
const today = Math.floor(now / DAY_MS);
const row = { day: today, opens: 1, closes: 0, seconds: 0 };
const post = (body: string, id: string = crypto.randomUUID()) => broker.fetch(
  new Request("https://broker.example/v1/app-usage", { method: "POST", headers: { "Lively-Usage-ID": id }, body }), env);

afterEach(() => vi.restoreAllMocks());

beforeEach(async () => {
  vi.spyOn(Date, "now").mockReturnValue(now);
  await env.DB.batch(["counters", "app_usage_days"].map(table => env.DB.prepare("DELETE FROM " + table)));
});

it("rejects malformed and oversized batches before writing any counters", async () => {
  for (const bad of [null, { day: today }, { ...row, seconds: 2 }, { ...row, opens: -1 }, { ...row, closes: 1.5 }]) {
    expect((await post(JSON.stringify({ platform: "ios", days: [row, bad] }))).status).toBe(400);
  }
  for (const body of ["{", " ".repeat(4097), JSON.stringify({ platform: "other", days: [row] }),
    JSON.stringify({ platform: "ios", days: Array(31).fill(row) })]) {
    expect((await post(body)).status).toBe(400);
  }
  expect((await post(JSON.stringify({ platform: "macos", days: [row] }), "account@example.com")).status).toBe(400);
  expect(await env.DB.prepare("SELECT count(*) AS n FROM app_usage_days").first("n")).toBe(0);
  expect(await env.DB.prepare("SELECT count(*) AS n FROM counters").first("n")).toBe(0);
});

it("limits repeated writes from one install and expires data outside the reporting period", async () => {
  const id = crypto.randomUUID();
  const body = JSON.stringify({ platform: "android", days: [row, { ...row, day: today - 29 }] });
  for (let i = 0; i < 30; i++) expect((await post(body, id)).status).toBe(204);
  expect((await post(body, id)).status).toBe(429);
  await env.DB.prepare("UPDATE app_usage_days SET day = day - 1").run();
  await broker.scheduled({} as ScheduledController, env);
  expect((await env.DB.prepare("SELECT day FROM app_usage_days").all()).results).toEqual([{ day: today - 1 }]);
});
