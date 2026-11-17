import { error, json, type Env } from "./broker";
import PINNED from "./voice-manifest.json";

/**
 * The offline voice pack the app downloads (Kokoro, CoreML). This manifest is
 * the pin: the app asks for it before each download, so changing
 * `voice-manifest.json` and deploying moves every later download to the new
 * revision without an app release. The app still checks each file's size and
 * SHA-256 against it, and only accepts a layout its runtime can load.
 */
export interface VoiceManifest {
  schemaVersion: number;
  id: string;
  /** The Hugging Face repository the files are copied from. */
  repository: string;
  /** A full commit hash, so a file never changes under its checksum. */
  revision: string;
  files: { path: string; size: number; sha256: string }[];
}

const MANIFEST_PATH = "/v1/voices/manifest";
const FILES_PREFIX = "/v1/voices/files/";
const UPSTREAM = "https://huggingface.co";

export function isVoiceRoute(pathname: string): boolean {
  return pathname === MANIFEST_PATH || pathname.startsWith(FILES_PREFIX);
}

/**
 * `GET /v1/voices/manifest` and `GET /v1/voices/files/<revision>/<path>`.
 * Files are served from the R2 bucket `VOICES`. A file that isn't there yet
 * is copied from Hugging Face first, and R2 rejects the copy unless it matches
 * the manifest's SHA-256. Only the pinned revision's files are served, so this
 * is never an open proxy. Neither route takes an install ID or a session.
 */
export async function voices(request: Request, env: Env, manifest: VoiceManifest = PINNED): Promise<Response> {
  if (request.method !== "GET") return error(405, "method_not_allowed", "Use GET.");
  const { pathname } = new URL(request.url);
  if (pathname === MANIFEST_PATH) return json(200, manifest, { "Cache-Control": "public, max-age=300" });

  let wanted: string;
  try {
    wanted = decodeURIComponent(pathname.slice(FILES_PREFIX.length));
  } catch {
    return error(404, "not_found", "No such voice file.");
  }
  const prefix = `${manifest.revision}/`;
  const file = wanted.startsWith(prefix) ? manifest.files.find((entry) => entry.path === wanted.slice(prefix.length)) : undefined;
  if (!file) return error(404, "not_found", "No such voice file.");

  const key = `${manifest.id}/${manifest.revision}/${file.path}`;
  let object = await env.VOICES.get(key);
  if (!object || object.size !== file.size) {
    if (!(await store(env, manifest, file, key))) {
      return error(502, "voice_source_unavailable", "The voice file couldn't be fetched. Try again.", 30);
    }
    object = await env.VOICES.get(key);
    if (!object) return error(502, "voice_source_unavailable", "The voice file couldn't be fetched. Try again.", 30);
  }
  return new Response(object.body, {
    headers: {
      // The revision is in the URL, so a stored file never changes.
      "Cache-Control": "public, max-age=31536000, immutable",
      "Content-Length": String(object.size),
      "Content-Type": "application/octet-stream",
      ETag: object.httpEtag,
      "X-Content-Type-Options": "nosniff",
    },
  });
}

/** Copies one file from Hugging Face into R2. False if it's missing there or isn't the pinned bytes. */
async function store(env: Env, manifest: VoiceManifest, file: VoiceManifest["files"][number], key: string): Promise<boolean> {
  const path = file.path.split("/").map(encodeURIComponent).join("/");
  try {
    const upstream = await fetch(`${UPSTREAM}/${manifest.repository}/resolve/${manifest.revision}/${path}`);
    if (!upstream.ok || !upstream.body) {
      await upstream.body?.cancel();
      return false;
    }
    // R2 needs the length up front, and this fails the copy if it's wrong.
    const sized = new FixedLengthStream(file.size);
    const copying = upstream.body.pipeTo(sized.writable);
    const [stored] = await Promise.allSettled([env.VOICES.put(key, sized.readable, { sha256: file.sha256 }), copying]);
    return stored.status === "fulfilled";
  } catch {
    return false;
  }
}
