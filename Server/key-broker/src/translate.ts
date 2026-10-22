/**
 * Text translation for turns the speech engine doesn't translate, such as
 * typed lines. DeepSeek translates them through Cloudflare AI Gateway, so the
 * DeepSeek key stays here and every request counts against the caller's plan.
 *
 *   POST /v1/translate
 *   (the same identifying headers as /v1/soniox/key)
 *   {"text": "…", "source": "en", "target": "zh", "script": "simplified",
 *    "context": [{"source": "…", "translation": "…"}]}
 *   → 200 text/event-stream of OpenAI-style chat completion chunks
 *
 * The prompt is fixed here, not sent by the app, so the endpoint only
 * translates. `context` is the last few turns, for pronouns, names and topic.
 */

import { applyCharges, chargesFor, error, identify, refund, type Env } from "./broker";

const LANGUAGE = /^[a-z]{2,3}$/;
const MAX_CONTEXT_TURNS = 3;

const SYSTEM = (source: string, target: string) =>
  `You are a live interpreter between ${source} and ${target} in a spoken, face-to-face ` +
  `conversation. Translate the user's message into ${target}. The text is a speech transcript and ` +
  `may be unpunctuated or end mid-sentence; translate it naturally, as a person would say it, and ` +
  `don't complete unfinished thoughts. Keep names, numbers and units exact. Reply with the ` +
  `translation only: no quotes, notes or romanization.`;

interface TranslateRequest {
  text: string;
  source: string;
  target: string;
  script?: "simplified" | "traditional";
  context?: { source: string; translation: string }[];
}

export async function translate(request: Request, env: Env, now: number): Promise<Response> {
  const caller = await identify(request, env, now);
  if (caller instanceof Response) return caller;

  const body = parse(await request.json().catch(() => null), int(env.TRANSLATE_MAX_CHARS, "TRANSLATE_MAX_CHARS"));
  if (typeof body === "string") return error(400, "bad_request", body);

  const plan = caller.plan;
  const charges = chargesFor(caller, now, "tr:", 1, {
    owner:
      plan === "pro"
        ? { perMinute: int(env.PRO_TRANSLATIONS_PER_MINUTE, "PRO_TRANSLATIONS_PER_MINUTE"), perDay: int(env.PRO_TRANSLATIONS_PER_DAY, "PRO_TRANSLATIONS_PER_DAY") }
        : { perMinute: int(env.PER_USER_TRANSLATIONS_PER_MINUTE, "PER_USER_TRANSLATIONS_PER_MINUTE"), perDay: int(env.PER_USER_TRANSLATIONS_PER_DAY, "PER_USER_TRANSLATIONS_PER_DAY") },
    install: { perMinute: int(env.PER_INSTALL_TRANSLATIONS_PER_MINUTE, "PER_INSTALL_TRANSLATIONS_PER_MINUTE"), perDay: int(env.PER_INSTALL_TRANSLATIONS_PER_DAY, "PER_INSTALL_TRANSLATIONS_PER_DAY") },
    ip: { perMinute: int(env.PER_IP_TRANSLATIONS_PER_MINUTE, "PER_IP_TRANSLATIONS_PER_MINUTE"), perDay: int(env.PER_IP_TRANSLATIONS_PER_DAY, "PER_IP_TRANSLATIONS_PER_DAY") },
    globalPerDay: int(env.GLOBAL_TRANSLATIONS_PER_DAY, "GLOBAL_TRANSLATIONS_PER_DAY"),
  });
  const applied = await applyCharges(env, charges, now, plan, {
    free: "Today's free text translations are used up.",
    pro: "Today's text translations are used up.",
  });
  if (applied instanceof Response) return applied;

  const name = (code: string) => languageName(code, body.script);
  const messages = [{ role: "system", content: SYSTEM(name(body.source), name(body.target)) }];
  for (const turn of body.context ?? []) {
    messages.push({ role: "user", content: turn.source }, { role: "assistant", content: turn.translation });
  }
  messages.push({ role: "user", content: body.text });

  let upstream: Response;
  try {
    upstream = await env.AI.gateway(env.AI_GATEWAY_ID).run({
      provider: "deepseek",
      endpoint: "chat/completions",
      headers: {
        ...(env.DEEPSEEK_API_KEY ? { Authorization: `Bearer ${env.DEEPSEEK_API_KEY}` } : {}),
        "Content-Type": "application/json",
        "cf-aig-collect-log": false,
      },
      query: {
        model: env.DEEPSEEK_MODEL,
        messages,
        stream: true,
        temperature: 0.2,
        max_tokens: 1000,
        // Live translation needs a fast first token, so no reasoning.
        thinking: { type: "disabled" },
      },
    });
  } catch (e) {
    console.error("AI Gateway request failed", e);
    await refund(env, charges);
    return error(502, "upstream", "Couldn't reach the translation service.", 2);
  }
  if (!upstream.ok || !upstream.body) {
    console.error("DeepSeek returned", upstream.status, await upstream.text().catch(() => ""));
    await refund(env, charges);
    return error(502, "upstream", "The translation service didn't answer.", 5);
  }
  return new Response(upstream.body, {
    headers: { "Content-Type": "text/event-stream", "Cache-Control": "no-store", "Lively-Plan": plan },
  });
}

/** The request body, or why it's unusable. */
function parse(value: unknown, maxChars: number): TranslateRequest | string {
  if (!value || typeof value !== "object") return "Send a JSON body.";
  const { text, source, target, script, context } = value as Record<string, unknown>;
  if (typeof text !== "string" || !text.trim()) return "`text` is required.";
  if (typeof source !== "string" || !LANGUAGE.test(source)) return "`source` must be a language code.";
  if (typeof target !== "string" || !LANGUAGE.test(target) || target === source) return "`target` must be another language code.";
  if (script !== undefined && script !== "simplified" && script !== "traditional") return "`script` must be simplified or traditional.";
  if (context !== undefined && !Array.isArray(context)) return "`context` must be a list.";
  const turns = (context ?? []).slice(-MAX_CONTEXT_TURNS);
  if (!turns.every((t) => t && typeof t.source === "string" && typeof t.translation === "string")) {
    return "Each `context` turn needs `source` and `translation`.";
  }
  const chars = text.length + turns.reduce((n, t) => n + t.source.length + t.translation.length, 0);
  if (chars > maxChars) return `Text and context are limited to ${maxChars} characters.`;
  return { text: text.trim(), source, target, script, context: turns };
}

/** "English", or "Simplified Chinese" / "Traditional Chinese" for zh. */
export function languageName(code: string, script?: TranslateRequest["script"]): string {
  if (code === "zh") return script === "traditional" ? "Traditional Chinese" : "Simplified Chinese";
  try {
    return new Intl.DisplayNames(["en"], { type: "language" }).of(code) ?? code;
  } catch {
    return code;
  }
}

function int(value: string, name: string): number {
  const n = Number.parseInt(value, 10);
  if (!Number.isFinite(n) || n < 0) throw new Error(`${name} must be a non-negative integer`);
  return n;
}
