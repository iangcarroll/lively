export { StaffReports } from "./staff/reports";
import { attributeAppleAds } from "./apple-ads";
import { appStoreNotification } from "./appstore";
import { deleteAccount, deleteExpiredAuth, logout, me, startEmailSignIn, verifyEmailSignIn } from "./auth";
import { error, issueSonioxKey, issueSonioxSpeechKey, json, nowSeconds, type Env } from "./broker";
import { appleAccountNotification, appleSignIn, googleSignIn } from "./identity";
import { translate } from "./translate";
import { isVoiceRoute, voices } from "./voices";

const SUPPORT_EMAIL = "support@lively.cautela.hk";
const PUBLIC_ORIGIN = "https://lively.cautela.hk";
const PUBLIC_PAGES = new Set(["/", "/privacy", "/support", "/terms", "/delete-account"]);

const privacy = page(
  "Privacy Policy",
  `<p><strong>Last updated November 19, 2026</strong></p>
  <p>Cautela Limited, a Hong Kong company, operates Lively. This policy explains how we handle your information when you use Lively and the choices you have. You can translate without creating an account.</p>
  <h2>Your conversations</h2>
  <p>With on-device translation, supported speech and text stay on your device. When you choose online translation, our speech and translation providers receive the audio or text needed to translate your conversation. This includes text you select from a photo. The photo itself stays on your device.</p>
  <p>We do not keep a copy of your conversations on our servers or use them for advertising. Your current conversation stays in the app until you clear it or the session ends. You can stop listening at any time using the microphone button.</p>
  <h2>Accounts and purchases</h2>
  <p>If you create an account, we use your email address and sign-in information to recognize you and provide your listening allowance. If you use Apple’s Hide My Email, we receive the address Apple provides. We use your email to operate your account and respond to you.</p>
  <p>Apple or Google processes your payment for Lively Pro. We receive subscription details, including the plan, purchase dates and a purchase identifier, to provide Pro access and handle renewals and refunds. We do not receive your payment card details.</p>
  <h2>Usage and advertising</h2>
  <p>We use information about your installation, network address and usage to apply daily limits and prevent abuse. We keep usage counts for a limited time.</p>
  <p>If you find Lively through an App Store ad, Apple may tell us which campaign and keyword led to your download. We use that information to measure how often those downloads lead to a paid Pro subscription. Lively does not show ads, sell personal information or track you across other companies’ apps and websites.</p>
  <h2>Service providers</h2>
  <p>Our service providers include Soniox and DeepSeek for speech and translation, and Cloudflare for hosting. If you choose Mistral, its privacy policy and your account settings apply to the audio and text you send.</p>
  <p>On iPhone and iPad, Apple Maps receives the places you look up. If you choose to set your language by location, Apple uses your approximate location to identify the country.</p>
  <p>Read the privacy policies of <a href="https://soniox.com/policies/privacy-policy">Soniox</a>, <a href="https://cdn.deepseek.com/policies/en-US/deepseek-privacy-policy.html">DeepSeek</a>, <a href="https://mistral.ai/terms#privacy-policy">Mistral</a>, <a href="https://www.cloudflare.com/privacypolicy/">Cloudflare</a> and <a href="https://www.apple.com/legal/privacy/">Apple</a> for more about their practices.</p>
  <h2>Your choices and contact information</h2>
  <p>You can delete your account in Settings → Account → Delete Account or on our <a href="/delete-account">account deletion page</a>. This deletes your email, sign-in information and active sessions. Apple or Google manages your subscription separately.</p>
  <p>For privacy questions or requests about your information, email <a href="mailto:${SUPPORT_EMAIL}">${SUPPORT_EMAIL}</a>.</p>`,
);

const support = page(
  "Support",
  `<p>Lively provides live conversation translation for iPhone, iPad, Mac and Android.</p>
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
  <p>If you signed in with Apple and chose to hide your email, delete the account in the app instead.</p>
  <form id="email-form"><label for="email">Account email</label><input id="email" type="email" autocomplete="email" required><button type="submit">Email me a code</button></form>
  <form id="code-form" hidden><label for="code">6-digit code</label><input id="code" inputmode="numeric" autocomplete="one-time-code" pattern="[0-9]{6}" required><button class="danger" type="submit">Delete account permanently</button></form>
  <p id="status" role="status" aria-live="polite"></p>
  <p>If you need help, email <a href="mailto:${SUPPORT_EMAIL}">${SUPPORT_EMAIL}</a>.</p>
  <script src="/delete-account.js" defer></script>`,
);

const accountDeletionScript = `const emailForm=document.querySelector('#email-form');const codeForm=document.querySelector('#code-form');const email=document.querySelector('#email');const code=document.querySelector('#code');const status=document.querySelector('#status');let address='';async function call(path,options){const response=await fetch(path,options);const body=await response.json().catch(()=>({}));if(!response.ok)throw new Error(body.message||'Something went wrong. Try again.');return body}emailForm.addEventListener('submit',async event=>{event.preventDefault();address=email.value.trim();status.textContent='Sending code…';try{await call('/v1/auth/email/start',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({email:address})});emailForm.hidden=true;codeForm.hidden=false;status.textContent='Enter the code sent to '+address+'.';code.focus()}catch(error){status.textContent=error.message}});codeForm.addEventListener('submit',async event=>{event.preventDefault();status.textContent='Deleting account…';try{const signedIn=await call('/v1/auth/email/verify',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({email:address,code:code.value})});await call('/v1/auth/delete',{method:'POST',headers:{Authorization:'Bearer '+signedIn.token}});codeForm.hidden=true;status.textContent='Your Lively account and associated data have been deleted.'}catch(error){status.textContent=error.message}});`;

const terms = page(
  "Terms of Use",
  `<p><strong>Effective November 16, 2026</strong></p>
  <p>Lively is provided by Cautela Limited, a Hong Kong company. Your use of Lively is governed by <a href="https://www.apple.com/legal/internet-services/itunes/dev/stdeula/">Apple's Licensed Application End User License Agreement</a>, together with these terms.</p>
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
  "/v1/auth/apple/notifications": { method: "POST", handle: appleAccountNotification },
  "/v1/auth/apple": { method: "POST", handle: appleSignIn },
  "/v1/auth/google": { method: "POST", handle: googleSignIn },
  "/v1/auth/me": { method: "GET", handle: me },
  "/v1/auth/logout": { method: "POST", handle: logout },
  "/v1/auth/delete": { method: "POST", handle: deleteAccount },
  "/v1/apple-ads/attribution": { method: "POST", handle: attributeAppleAds },
  "/v1/appstore/notifications": { method: "POST", handle: appStoreNotification },
};

// The entry module may only export handlers, so the logic lives in broker.ts.
export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);
    // Move human-facing pages while preserving API calls from installed builds.
    // Redirecting authenticated API requests across hosts can drop their headers.
    if (url.hostname === "lively.ian.sh" && PUBLIC_PAGES.has(url.pathname)
      && (request.method === "GET" || request.method === "HEAD")) {
      return Response.redirect(`${PUBLIC_ORIGIN}${url.pathname}${url.search}`, 308);
    }
    if (url.pathname === "/healthz") return json(200, { ok: true });
    if (url.pathname === "/privacy") return html(privacy);
    if (url.pathname === "/" || url.pathname === "/support") return html(support);
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
    if (isVoiceRoute(url.pathname)) return voices(request, env);
    const route = Object.hasOwn(ROUTES, url.pathname) ? ROUTES[url.pathname] : undefined;
    if (!route) return error(404, "not_found", "No such endpoint.");
    if (request.method !== route.method) return error(405, "method_not_allowed", `Use ${route.method}.`);
    return route.handle(request, env, Date.now());
  },

  async scheduled(_controller: ScheduledController, env: Env): Promise<void> {
    const now = Date.now();
    await env.DB.prepare("DELETE FROM counters WHERE expires_at < ?").bind(nowSeconds(now)).run();
    await deleteExpiredAuth(env, now);
    await env.DB.prepare(`DELETE FROM subscription_observations
      WHERE observed_ms < ?1 AND (period_end_ms IS NULL OR period_end_ms < ?1)`)
      .bind(now - 90 * 86_400_000).run();
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
  return `<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>Lively — ${title}</title><style>:root{color-scheme:light dark;font:17px/1.55 system-ui,-apple-system,sans-serif}body{max-width:720px;margin:0 auto;padding:48px 24px 80px}h1{font-size:2.25rem;letter-spacing:-.03em;margin-bottom:.25em}h2{font-size:1.25rem;margin-top:2em}a{color:#4f46e5}form{display:grid;gap:.6rem;margin:1.5rem 0;max-width:28rem}label{font-weight:600}input,button{box-sizing:border-box;font:inherit;padding:.7rem .8rem;border-radius:.5rem;border:1px solid color-mix(in srgb,currentColor 35%,transparent)}button{width:max-content;cursor:pointer;font-weight:600}.danger{color:#fff;background:#b91c1c;border-color:#b91c1c}[hidden]{display:none!important}@media(prefers-color-scheme:dark){a{color:#a5b4fc}}footer{border-top:1px solid color-mix(in srgb,currentColor 20%,transparent);margin-top:3rem;padding-top:1rem;opacity:.7}</style><main><h1>${title}</h1>${content}</main><footer>Lively · Live conversation translation</footer></html>`;
}
