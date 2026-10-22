import { appStoreNotification } from "./appstore";
import { deleteAccount, deleteExpiredAuth, logout, me, startEmailSignIn, verifyEmailSignIn } from "./auth";
import { error, issueSonioxKey, json, nowSeconds, type Env } from "./broker";

const SUPPORT_EMAIL = "support@lively.ian.sh";

const privacy = page(
  "Privacy Policy",
  `<p><strong>Effective October 22, 2026</strong></p>
  <p>Lively translates live English and Chinese conversations. It is designed to work without an account, advertising, analytics, or tracking.</p>
  <h2>Speech and translations</h2>
  <p>When you start listening, Lively sends microphone audio to the speech provider selected in Settings so it can transcribe and translate the conversation in real time. The default provider is Soniox. Soniox says its real-time API processes audio, transcripts, and translations transiently, does not store that content, and does not use it to train models.</p>
  <p>If you choose the optional Voxtral + Mistral engine, Lively sends audio and transcript text directly to Mistral using the API key you provide. Mistral's terms and privacy practices apply to that processing.</p>
  <p>The conversation shown in Lively remains on your device for the current app session. Lively does not upload it to its own servers.</p>
  <h2>Temporary keys and abuse prevention</h2>
  <p>To use the default provider without creating an account, the app creates a random installation identifier and stores it in your device Keychain. Lively's key service receives that identifier and your network address to enforce usage limits and prevent abuse. It stores one-way hashes and short-lived counters, not your raw identifier, raw network address, audio, or transcript.</p>
  <h2>Optional account</h2>
  <p>You can optionally sign in for a larger listening allowance. If you do, Lively collects your email address, stores it with a randomly generated account identifier, and stores only hashes of sign-in codes and session tokens. Your email is used only to send a requested sign-in code and operate your account. It is not used for marketing or linked to your conversation content.</p>
  <p>You can delete your account at any time in Settings → Account → Delete Account. This immediately deletes your email address, account identifier and sessions from Lively's servers.</p>
  <h2>Lively Pro purchases</h2>
  <p>Lively Pro is sold through Apple's App Store, and Apple processes your payment. Lively never receives your payment details or Apple ID. To check that a subscription is active, the app sends Lively's key service the signed transaction record the App Store issued, which includes the product, its purchase and expiry dates, and a transaction identifier. Lively uses it only to apply your Pro allowance, and keeps a one-way hash of the transaction identifier in short-lived usage counters. If a purchase is refunded, Lively stores that transaction identifier to stop the refunded subscription from being used.</p>
  <h2>Data we do not use</h2>
  <p>Lively does not sell personal information, show ads, track you across apps or websites, or use conversation content for marketing or analytics.</p>
  <h2>Your choices</h2>
  <p>You can stop transmission at any time by tapping the microphone button. You can clear the visible conversation in the app. Uninstalling Lively removes its local app data. The random installation identifier may remain in your device Keychain after deletion, but it is not linked to your identity.</p>
  <h2>Third-party services</h2>
  <ul><li><a href="https://soniox.com/policies/privacy-policy">Soniox Privacy Policy</a></li><li><a href="https://mistral.ai/terms#privacy-policy">Mistral Privacy Policy</a></li></ul>
  <h2>Contact</h2>
  <p>For privacy questions, email <a href="mailto:${SUPPORT_EMAIL}">${SUPPORT_EMAIL}</a>.</p>`,
);

const support = page(
  "Support",
  `<p>Lively provides live English ⇄ Chinese conversation translation for iPhone and iPad.</p>
  <h2>Before reporting a problem</h2>
  <ul><li>Confirm that microphone access is enabled in Settings → Privacy &amp; Security → Microphone.</li><li>Check that the device has an internet connection.</li><li>Stop and restart listening after changing engines or translation settings.</li></ul>
  <h2>Lively Pro</h2>
  <ul><li>To restore a subscription on a new device, open Settings → Lively Pro → Restore Purchases.</li><li>To cancel, open the Settings app → your name → Subscriptions → Lively. You keep Pro until the end of the period you paid for.</li><li>For refunds, use <a href="https://reportaproblem.apple.com">Apple's Report a Problem</a>. Apple handles all App Store payments.</li></ul>
  <h2>Your account</h2>
  <p>To delete your account, open Settings → Account → Delete Account. Deleting it doesn't cancel a Lively Pro subscription.</p>
  <h2>Get help</h2>
  <p>Email <a href="mailto:${SUPPORT_EMAIL}">${SUPPORT_EMAIL}</a> to report a problem or ask a question. Please do not include private conversation audio, transcripts, API keys, or other sensitive information.</p>
  <p>See also the <a href="/privacy">privacy policy</a> and the <a href="/terms">terms of use</a>.</p>`,
);

const terms = page(
  "Terms of Use",
  `<p><strong>Effective October 22, 2026</strong></p>
  <p>Lively is provided by Certly, Inc. Your use of Lively is governed by <a href="https://www.apple.com/legal/internet-services/itunes/dev/stdeula/">Apple's Licensed Application End User License Agreement</a>, together with these terms.</p>
  <h2>Lively Pro</h2>
  <p>Lively Pro is an auto-renewing subscription that raises your daily translation allowance. Payment is charged to your Apple ID when you confirm the purchase. The subscription renews automatically at the same price for the same period unless you turn off auto-renewal at least 24 hours before the current period ends. You can manage or cancel it in the Settings app → your name → Subscriptions. Cancelling takes effect at the end of the current period. Apple handles refunds.</p>
  <p>Pro use is subject to a fair-use daily limit, shown in the app, to keep the service available for everyone.</p>
  <h2>Translations</h2>
  <p>Lively's transcriptions and translations are produced automatically and can be wrong or incomplete. Don't rely on them where a mistake could cause harm, such as medical, legal, or safety-critical situations.</p>
  <h2>Acceptable use</h2>
  <p>Don't use Lively to record people without their consent where the law requires it, or to get around its usage limits. We may suspend access that abuses the service.</p>
  <h2>Contact</h2>
  <p>Email <a href="mailto:${SUPPORT_EMAIL}">${SUPPORT_EMAIL}</a>.</p>`,
);

const ROUTES: Record<string, { method: string; handle: (request: Request, env: Env, now: number) => Promise<Response> }> = {
  "/v1/soniox/key": { method: "POST", handle: issueSonioxKey },
  "/v1/auth/email/start": { method: "POST", handle: startEmailSignIn },
  "/v1/auth/email/verify": { method: "POST", handle: verifyEmailSignIn },
  "/v1/auth/me": { method: "GET", handle: me },
  "/v1/auth/logout": { method: "POST", handle: logout },
  "/v1/auth/delete": { method: "POST", handle: deleteAccount },
  "/v1/appstore/notifications": { method: "POST", handle: appStoreNotification },
};

// The entry module may only export handlers, so the logic lives in broker.ts.
export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);
    if (url.pathname === "/healthz") return json(200, { ok: true });
    if (url.pathname === "/privacy") return html(privacy);
    if (url.pathname === "/support") return html(support);
    if (url.pathname === "/terms") return html(terms);
    const route = Object.hasOwn(ROUTES, url.pathname) ? ROUTES[url.pathname] : undefined;
    if (!route) return error(404, "not_found", "No such endpoint.");
    if (request.method !== route.method) return error(405, "method_not_allowed", `Use ${route.method}.`);
    return route.handle(request, env, Date.now());
  },

  async scheduled(_controller: ScheduledController, env: Env): Promise<void> {
    const now = Date.now();
    await env.DB.prepare("DELETE FROM counters WHERE expires_at < ?").bind(nowSeconds(now)).run();
    await deleteExpiredAuth(env, now);
  },
} satisfies ExportedHandler<Env>;

function html(body: string): Response {
  return new Response(body, {
    headers: {
      "Cache-Control": "public, max-age=3600",
      "Content-Security-Policy": "default-src 'none'; style-src 'unsafe-inline'; img-src data:; base-uri 'none'; form-action 'none'; frame-ancestors 'none'",
      "Content-Type": "text/html; charset=utf-8",
      "Referrer-Policy": "no-referrer",
      "X-Content-Type-Options": "nosniff",
    },
  });
}

function page(title: string, content: string): string {
  return `<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>Lively — ${title}</title><style>:root{color-scheme:light dark;font:17px/1.55 system-ui,-apple-system,sans-serif}body{max-width:720px;margin:0 auto;padding:48px 24px 80px}h1{font-size:2.25rem;letter-spacing:-.03em;margin-bottom:.25em}h2{font-size:1.25rem;margin-top:2em}a{color:#4f46e5}@media(prefers-color-scheme:dark){a{color:#a5b4fc}}footer{border-top:1px solid color-mix(in srgb,currentColor 20%,transparent);margin-top:3rem;padding-top:1rem;opacity:.7}</style><main><h1>${title}</h1>${content}</main><footer>Lively · English ⇄ Chinese conversation translation</footer></html>`;
}
