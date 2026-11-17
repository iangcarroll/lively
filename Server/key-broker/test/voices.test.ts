import { env } from "cloudflare:test";
import { afterEach, describe, expect, it, vi } from "vitest";
import worker from "../src/index";
import PINNED from "../src/voice-manifest.json";
import { voices, type VoiceManifest } from "../src/voices";

const REVISION = "0123456789abcdef0123456789abcdef01234567";

async function sha256(text: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text));
  return [...new Uint8Array(digest)].map((byte) => byte.toString(16).padStart(2, "0")).join("");
}

/** A one-file manifest with its own ID, so tests don't share R2 objects. */
async function manifestFor(content: string, path = "model/weights.bin"): Promise<VoiceManifest> {
  return {
    schemaVersion: 1,
    id: `test-${crypto.randomUUID()}`,
    repository: "owner/voices",
    revision: REVISION,
    files: [{ path, size: content.length, sha256: await sha256(content) }],
  };
}

function fileRequest(path: string, method = "GET"): Request {
  return new Request(`https://broker.test/v1/voices/files/${path}`, { method });
}

function upstream(respond: () => Response) {
  return vi.spyOn(globalThis, "fetch").mockImplementation(async () => respond());
}

afterEach(() => vi.restoreAllMocks());

describe("GET /v1/voices/manifest", () => {
  it("serves the pinned manifest without calling Hugging Face", async () => {
    const fetched = upstream(() => new Response("unused"));
    const response = await worker.fetch(new Request("https://broker.test/v1/voices/manifest"), env);

    expect(response.status).toBe(200);
    const body = (await response.json()) as VoiceManifest;
    expect(body.revision).toMatch(/^[0-9a-f]{40}$/);
    expect(body.schemaVersion).toBe(1);
    expect(body.files.length).toBe(PINNED.files.length);
    expect(fetched).not.toHaveBeenCalled();
  });

  it("rejects other methods", async () => {
    const response = await worker.fetch(new Request("https://broker.test/v1/voices/manifest", { method: "POST" }), env);
    expect(response.status).toBe(405);
  });
});

describe("GET /v1/voices/files", () => {
  it("copies a file from the pinned revision once, then serves it from R2", async () => {
    const manifest = await manifestFor("voice bytes");
    const fetched = upstream(() => new Response("voice bytes"));

    const first = await voices(fileRequest(`${REVISION}/model/weights.bin`), env, manifest);
    expect(first.status).toBe(200);
    expect(first.headers.get("Content-Length")).toBe("11");
    expect(first.headers.get("Cache-Control")).toContain("immutable");
    expect(await first.text()).toBe("voice bytes");
    expect(String(fetched.mock.calls[0][0])).toBe(`https://huggingface.co/owner/voices/resolve/${REVISION}/model/weights.bin`);

    const second = await voices(fileRequest(`${REVISION}/model/weights.bin`), env, manifest);
    expect(await second.text()).toBe("voice bytes");
    expect(fetched).toHaveBeenCalledTimes(1);
  });

  it("doesn't store or serve bytes that fail the pinned checksum", async () => {
    const manifest = await manifestFor("voice bytes");
    upstream(() => new Response("VOICE BYTES"));

    const response = await voices(fileRequest(`${REVISION}/model/weights.bin`), env, manifest);
    expect(response.status).toBe(502);
    expect(await env.VOICES.get(`${manifest.id}/${REVISION}/model/weights.bin`)).toBeNull();
  });

  it("doesn't store a file of the wrong length", async () => {
    const manifest = await manifestFor("voice bytes");
    upstream(() => new Response("voice bytes and more"));

    const response = await voices(fileRequest(`${REVISION}/model/weights.bin`), env, manifest);
    expect(response.status).toBe(502);
    expect(await env.VOICES.get(`${manifest.id}/${REVISION}/model/weights.bin`)).toBeNull();
  });

  it("reports a missing upstream file as unavailable", async () => {
    const manifest = await manifestFor("voice bytes");
    upstream(() => new Response("gone", { status: 404 }));

    const response = await voices(fileRequest(`${REVISION}/model/weights.bin`), env, manifest);
    expect(response.status).toBe(502);
    expect(response.headers.get("Retry-After")).toBe("30");
  });

  it("serves only the pinned revision's listed files", async () => {
    const manifest = await manifestFor("voice bytes");
    const fetched = upstream(() => new Response("voice bytes"));

    for (const path of [
      `${"f".repeat(40)}/model/weights.bin`,
      `${REVISION}/model/other.bin`,
      `${REVISION}/../secrets`,
      `${REVISION}/`,
      "model/weights.bin",
      "%E0%A4%A",
    ]) {
      expect((await voices(fileRequest(path), env, manifest)).status, path).toBe(404);
    }
    expect(fetched).not.toHaveBeenCalled();
    expect((await voices(fileRequest(`${REVISION}/model/weights.bin`, "POST"), env, manifest)).status).toBe(405);
  });
});

describe("the pinned voice manifest", () => {
  it("names a full commit and safe, checksummed paths", () => {
    expect(PINNED.revision).toMatch(/^[0-9a-f]{40}$/);
    expect(PINNED.repository).toMatch(/^[\w.-]+\/[\w.-]+$/);
    expect(new Set(PINNED.files.map((file) => file.path)).size).toBe(PINNED.files.length);
    for (const file of PINNED.files) {
      expect(file.sha256).toMatch(/^[0-9a-f]{64}$/);
      expect(file.size).toBeGreaterThanOrEqual(0);
      expect(file.path.split("/").every((piece) => piece && piece !== "." && piece !== "..")).toBe(true);
    }
    expect(PINNED.files.reduce((sum, file) => sum + file.size, 0)).toBe(PINNED.totalBytes);
  });
});
