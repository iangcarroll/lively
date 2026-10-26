import { appStoreNotification } from "./appstore";
import { deleteAccount, deleteExpiredAuth, logout, me, startEmailSignIn, verifyEmailSignIn } from "./auth";
import { error, issueSonioxKey, issueSonioxSpeechKey, json, nowSeconds, type Env } from "./broker";
import { translate } from "./translate";

const SUPPORT_EMAIL = "support@lively.ian.sh";

const privacy = page(
  "Privacy Policy",
  `<p><strong>Effective October 23, 2026</strong></p>
  <p>Lively translates live English and Chinese conversations. It is designed to work without an account, advertising, analytics, or tracking.</p>
  <h2>Speech and translations</h2>
  <p>When you start listening, Lively sends microphone audio to the speech provider selected in Settings so it can transcribe and translate the conversation in real time. The default provider is Soniox. Soniox says its real-time API processes audio, transcripts, and translations transiently, does not store that content, and does not use it to train models.</p>
  <p>If you choose the optional Voxtral + Mistral engine, Lively sends audio and transcript text directly to Mistral using the API key you provide. Mistral's terms and privacy practices apply to that processing.</p>
  <p>When you type a line to translate, Lively sends that text and the last few turns of the conversation to Lively's key service, which has DeepSeek translate it through Cloudflare AI Gateway and returns the translation. Neither Lively's key service nor its gateway logs keep that text; DeepSeek's terms and privacy practices apply to its processing. If the key service can't be reached, the app translates on your device with Apple's Translation framework instead.</p>
  <p>The conversation shown in Lively remains on your device for the current app session. Lively does not store it on its own servers.</p>
  <h2>Temporary keys and abuse prevention</h2>
  <p>To use the default provider without creating an account, the app creates a random installation identifier and stores it in your device Keychain (on Android, in app storage encrypted with a key held by the Android Keystore). Lively's key service receives that identifier and your network address to enforce usage limits and prevent abuse. It stores one-way hashes and short-lived counters, not your raw identifier, raw network address, audio, or transcript.</p>
  <h2>Optional account</h2>
  <p>You can optionally sign in for a larger listening allowance. If you do, Lively collects your email address, stores it with a randomly generated account identifier, and stores only hashes of sign-in codes and session tokens. Your email is used only to send a requested sign-in code and operate your account. It is not used for marketing or linked to your conversation content.</p>
  <p>You can delete your account at any time in Settings → Account → Delete Account or at <a href="/delete-account">lively.ian.sh/delete-account</a>. This immediately deletes your email address, account identifier and sessions from Lively's servers.</p>
  <h2>Lively Pro purchases</h2>
  <p>Lively Pro is sold through Apple's App Store, and Apple processes your payment. Lively never receives your payment details or Apple ID. To check that a subscription is active, the app sends Lively's key service the signed transaction record the App Store issued, which includes the product, its purchase and expiry dates, and a transaction identifier. Lively uses it only to apply your Pro allowance, and keeps a one-way hash of the transaction identifier in short-lived usage counters. If a purchase is refunded, Lively stores that transaction identifier to stop the refunded subscription from being used.</p>
  <p>On Android, Lively Pro is sold through Google Play, and Google processes your payment. Lively never receives your payment details or Google account. To check that a subscription is active, the app sends Lively's key service the purchase token Google Play issued, and the key service asks Google for the subscription's product, status and expiry date. Lively uses it only to apply your Pro allowance, and keeps a one-way hash of the token in short-lived usage counters.</p>
  <h2>Data we do not use</h2>
  <p>Lively does not sell personal information, show ads, track you across apps or websites, or use conversation content for marketing or analytics.</p>
  <h2>Your choices</h2>
  <p>You can stop transmission at any time by tapping the microphone button. You can clear the visible conversation in the app. Uninstalling Lively removes its local app data. On iPhone and iPad, the random installation identifier may remain in your device Keychain after deletion, but it is not linked to your identity. On Android, uninstalling removes it.</p>
  <h2>Third-party services</h2>
  <ul><li><a href="https://soniox.com/policies/privacy-policy">Soniox Privacy Policy</a></li><li><a href="https://mistral.ai/terms#privacy-policy">Mistral Privacy Policy</a></li><li><a href="https://cdn.deepseek.com/policies/en-US/deepseek-privacy-policy.html">DeepSeek Privacy Policy</a></li><li><a href="https://www.cloudflare.com/privacypolicy/">Cloudflare Privacy Policy</a></li></ul>
  <h2>Contact</h2>
  <p>For privacy questions, email <a href="mailto:${SUPPORT_EMAIL}">${SUPPORT_EMAIL}</a>.</p>`,
);

const support = page(
  "Support",
  `<p>Lively provides live English ⇄ Chinese conversation translation for iPhone, iPad and Android.</p>
  <h2>Before reporting a problem</h2>
  <ul><li>Confirm that microphone access is enabled in Settings → Privacy &amp; Security → Microphone.</li><li>Check that the device has an internet connection.</li><li>Stop and restart listening after changing engines or translation settings.</li></ul>
  <h2>Lively Pro</h2>
  <ul><li>To restore a subscription on a new device, open Settings → Lively Pro → Restore Purchases.</li><li>To cancel, open the Settings app → your name → Subscriptions → Lively. You keep Pro until the end of the period you paid for.</li><li>For refunds, use <a href="https://reportaproblem.apple.com">Apple's Report a Problem</a>. Apple handles all App Store payments.</li><li>On Android, to cancel, open the Play Store app → your profile → Payments &amp; subscriptions → Subscriptions → Lively. Google handles all Google Play payments and refunds.</li></ul>
  <h2>Your account</h2>
  <p>To delete your account, open Settings → Account → Delete Account or use the <a href="/delete-account">account deletion page</a>. Deleting it doesn't cancel a Lively Pro subscription.</p>
  <h2>Get help</h2>
  <p>Email <a href="mailto:${SUPPORT_EMAIL}">${SUPPORT_EMAIL}</a> to report a problem or ask a question. Please do not include private conversation audio, transcripts, API keys, or other sensitive information.</p>
  <p>See also the <a href="/privacy">privacy policy</a> and the <a href="/terms">terms of use</a>.</p>`,
);

const accountDeletion = page(
  "Delete your account",
  `<p>Delete your optional Lively account and its associated data. You can also delete it while signed in under Settings → Account in the app.</p>
  <p>Deletion is immediate and permanent. It removes your email address, account identifier and all active sessions. Short-lived, one-way-hashed usage counters expire automatically and cannot be linked back to you after deletion. Lively does not store conversation audio or transcripts on its servers. Deleting your account does not cancel a Lively Pro subscription.</p>
  <form id="email-form"><label for="email">Account email</label><input id="email" type="email" autocomplete="email" required><button type="submit">Email me a code</button></form>
  <form id="code-form" hidden><label for="code">6-digit code</label><input id="code" inputmode="numeric" autocomplete="one-time-code" pattern="[0-9]{6}" required><button class="danger" type="submit">Delete account permanently</button></form>
  <p id="status" role="status" aria-live="polite"></p>
  <p>If you need help, email <a href="mailto:${SUPPORT_EMAIL}">${SUPPORT_EMAIL}</a>.</p>
  <script src="/delete-account.js" defer></script>`,
);

const accountDeletionScript = `const emailForm=document.querySelector('#email-form');const codeForm=document.querySelector('#code-form');const email=document.querySelector('#email');const code=document.querySelector('#code');const status=document.querySelector('#status');let address='';async function call(path,options){const response=await fetch(path,options);const body=await response.json().catch(()=>({}));if(!response.ok)throw new Error(body.message||'Something went wrong. Try again.');return body}emailForm.addEventListener('submit',async event=>{event.preventDefault();address=email.value.trim();status.textContent='Sending code…';try{await call('/v1/auth/email/start',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({email:address})});emailForm.hidden=true;codeForm.hidden=false;status.textContent='Enter the code sent to '+address+'.';code.focus()}catch(error){status.textContent=error.message}});codeForm.addEventListener('submit',async event=>{event.preventDefault();status.textContent='Deleting account…';try{const signedIn=await call('/v1/auth/email/verify',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({email:address,code:code.value})});await call('/v1/auth/delete',{method:'POST',headers:{Authorization:'Bearer '+signedIn.token}});codeForm.hidden=true;status.textContent='Your Lively account and associated data have been deleted.'}catch(error){status.textContent=error.message}});`;

const terms = page(
  "Terms of Use",
  `<p><strong>Effective October 22, 2026</strong></p>
  <p>Lively is provided by Certly, Inc. Your use of Lively is governed by <a href="https://www.apple.com/legal/internet-services/itunes/dev/stdeula/">Apple's Licensed Application End User License Agreement</a>, together with these terms.</p>
  <h2>Lively Pro</h2>
  <p>Lively Pro is an auto-renewing subscription that raises your daily translation allowance. Payment is charged to your Apple ID when you confirm the purchase. The subscription renews automatically at the same price for the same period unless you turn off auto-renewal at least 24 hours before the current period ends. You can manage or cancel it in the Settings app → your name → Subscriptions. Cancelling takes effect at the end of the current period. Apple handles refunds.</p>
  <p>On Android, Lively Pro is sold through Google Play under <a href="https://play.google.com/about/play-terms/">Google Play's Terms of Service</a>. Payment is charged to your Google account, and the subscription renews automatically until you cancel it in the Play Store app → Payments &amp; subscriptions. Cancelling takes effect at the end of the current period. Google handles refunds.</p>
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
  "/v1/soniox/tts-key": { method: "POST", handle: issueSonioxSpeechKey },
  "/v1/translate": { method: "POST", handle: translate },
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
    if (url.pathname === "/delete-account") return html(accountDeletion, true);
    if (url.pathname === "/delete-account.js") {
      return new Response(accountDeletionScript, {
        headers: {
          "Cache-Control": "public, max-age=3600",
          "Content-Type": "text/javascript; charset=utf-8",
          "Referrer-Policy": "no-referrer",
          "X-Content-Type-Options": "nosniff",
        },
      });
    }
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

function html(body: string, interactive = false): Response {
  return new Response(body, {
    headers: {
      "Cache-Control": "public, max-age=3600",
      "Content-Security-Policy": interactive
        ? "default-src 'none'; style-src 'unsafe-inline'; script-src 'self'; connect-src 'self'; base-uri 'none'; form-action 'self'; frame-ancestors 'none'"
        : "default-src 'none'; style-src 'unsafe-inline'; img-src data:; base-uri 'none'; form-action 'none'; frame-ancestors 'none'",
      "Content-Type": "text/html; charset=utf-8",
      "Referrer-Policy": "no-referrer",
      "X-Content-Type-Options": "nosniff",
    },
  });
}

function page(title: string, content: string): string {
  return `<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>Lively — ${title}</title><style>:root{color-scheme:light dark;font:17px/1.55 system-ui,-apple-system,sans-serif}body{max-width:720px;margin:0 auto;padding:48px 24px 80px}h1{font-size:2.25rem;letter-spacing:-.03em;margin-bottom:.25em}h2{font-size:1.25rem;margin-top:2em}a{color:#4f46e5}form{display:grid;gap:.6rem;margin:1.5rem 0;max-width:28rem}label{font-weight:600}input,button{box-sizing:border-box;font:inherit;padding:.7rem .8rem;border-radius:.5rem;border:1px solid color-mix(in srgb,currentColor 35%,transparent)}button{width:max-content;cursor:pointer;font-weight:600}.danger{color:#fff;background:#b91c1c;border-color:#b91c1c}[hidden]{display:none!important}@media(prefers-color-scheme:dark){a{color:#a5b4fc}}footer{border-top:1px solid color-mix(in srgb,currentColor 20%,transparent);margin-top:3rem;padding-top:1rem;opacity:.7}</style><main><h1>${title}</h1>${content}</main><footer>Lively · English ⇄ Chinese conversation translation</footer></html>`;
}
