# Lively key broker

A Cloudflare Worker that holds Lively's real Soniox API key and gives the app
short-lived, single-use temporary keys. The app connects to Soniox directly
with them, so audio never passes through the Worker.

```
POST /v1/soniox/key
Lively-Install-ID: 3F2C9A3E-6B1D-4C55-9A0E-2D7E8F1B4C6A
Lively-Region: jp                      (optional)

200 {"api_key": "...", "expires_at": "2026-10-21T01:00:34.125Z",
     "expires_in_seconds": 300, "max_session_seconds": 7200,
     "region": "jp",
     "websocket_url": "wss://stt-rt.jp.soniox.com/transcribe-websocket",
     "regions": {"us": "wss://stt-rt.soniox.com/transcribe-websocket",
                 "jp": "wss://stt-rt.jp.soniox.com/transcribe-websocket"},
     "plan": "free"}
```

For each request the Worker calls Soniox's
`POST https://api[.<region>].soniox.com/v1/auth/temporary-api-key` with:

| Field | Value |
|---|---|
| `usage_type` | `transcribe_websocket` |
| `expires_in_seconds` | `KEY_TTL_SECONDS` (300) |
| `single_use` | `true` |
| `max_session_duration_seconds` | `MAX_SESSION_SECONDS` (7200), or less near the day's limit |
| `client_reference_id` | first 128 bits of SHA-256 of the install ID, hex |

## Regions

Each Soniox region is a separate project with its own master key, and a
temporary key works only on its own region's WebSocket host
([data residency](https://soniox.com/docs/data-residency)).

| Region | Secret | Mints at | WebSocket |
|---|---|---|---|
| `us` | `SONIOX_API_KEY_US` (or the older `SONIOX_API_KEY`) | `api.soniox.com` | `stt-rt.soniox.com` |
| `jp` | `SONIOX_API_KEY_JP` | `api.jp.soniox.com` | `stt-rt.jp.soniox.com` |

A region without a secret is never offered. To pick the region, the Worker
tries these in order:

1. `Lively-Region`, if it's a region with a key. Anything else is ignored. The
   app sends the region its `RegionProber` measured as fastest.
2. Japan for callers in East and Southeast Asia and Oceania
   (`request.cf.country`), otherwise the US.
3. If Soniox won't mint in that region, the next one.

`regions` lists every region with a key, so the app knows what to probe.

To add Japan: in the Soniox Console, request Japan under Security & compliance
› Region access, wait for approval, create a project in Japan, set a budget on
it, then `npx wrangler secret put SONIOX_API_KEY_JP` with that project's key.

## Who gets keys

Callers can be anonymous. The app makes up a random UUID on first launch, keeps
it in the Keychain, and sends it as `Lively-Install-ID`. There's no App Attest,
so anyone who copies the request can get keys. A caller that has signed in
(see [Sign-in](#sign-in)) also sends `Authorization: Bearer <token>`. These
limits cap what that costs:

| Variable | Default | Limit |
|---|---|---|
| `PER_INSTALL_KEYS_PER_MINUTE` | 6 | keys per install per minute |
| `PER_INSTALL_MINUTES_PER_DAY` | 15 | listening minutes per install per UTC day |
| `PER_IP_KEYS_PER_MINUTE` | 30 | keys per IP per minute (IPv6 by /64) |
| `PER_IP_MINUTES_PER_DAY` | 1440 | listening minutes per IP per UTC day (anonymous only) |
| `PER_USER_KEYS_PER_MINUTE` | 10 | keys per account per minute |
| `PER_USER_MINUTES_PER_DAY` | 30 | listening minutes per account per UTC day |
| `PRO_KEYS_PER_MINUTE` | 10 | keys per Pro subscription or account per minute |
| `PRO_MINUTES_PER_DAY` | 600 | listening minutes per Pro subscription or account per UTC day |
| `GLOBAL_KEYS_PER_DAY` | 100000 | keys for everyone per UTC day |
| `KEY_CHARGE_SECONDS` | 120 | listening time charged per key |
| `DENYLIST` | empty | comma-separated install, account or subscription hashes to refuse |

A signed-in caller is charged per account instead of per install, so its budget
follows it across devices. It isn't held to the per-IP daily budget, since
people behind one carrier NAT would use up each other's time. The per-IP
per-minute limit and the global cap still apply. Its keys carry the account's
hash as `client_reference_id`. A token that isn't valid gets 401
`signed_out`; the app then drops it and asks again anonymously.

Listening time is estimated from keys. Keys live 5 minutes, so the app's
spare key outlasts a few minutes of broker trouble (common on mainland China
networks), and the app replaces it a minute before it expires, about every
240 s. Each key counts as 120 s: steady listening is undercounted about 2×,
but each reconnect, catch-up or handover session on a flaky network also
takes a key, and those shouldn't use up a day's budget. A client that skips the
refresh and holds one session open is still bounded, because each key's
`max_session_duration_seconds` is capped at what's left of the day's budget.

To cut off one install or account without a redeploy, add its hash (the
`client_reference_id` in Soniox's usage logs) to the D1 table:

```bash
npx wrangler d1 execute lively-key-broker --remote \
  --command "INSERT INTO denylist (install_hash, reason) VALUES ('<hash>', 'abuse')"
```

Change limits in `wrangler.jsonc` → `vars`, then deploy, or edit them in the
dashboard under Settings › Variables.

Errors are JSON `{error, message}`. A per-minute 429 carries a short
`Retry-After`, and the app retries it. A daily 429 (`Retry-After` over 60 s),
403 (denied) and 503 (global cap) stop listening and show `message`. A daily
429 also carries `plan`; on `free` the app offers Lively Pro.

## Text translation

Soniox translates speech itself, so text translation is only for turns it
doesn't cover, such as lines typed in the app. DeepSeek translates them through
Cloudflare AI Gateway; the Worker holds the prompt and the DeepSeek key.

```
POST /v1/translate
Lively-Install-ID: 3F2C9A3E-6B1D-4C55-9A0E-2D7E8F1B4C6A
(Authorization, Lively-Subscription and Lively-Play-Purchase as for keys)
{"text": "Hello!", "source": "en", "target": "zh", "script": "simplified",
 "context": [{"source": "…", "translation": "…"}]}

200 text/event-stream: OpenAI-style chat completion chunks
```

- The model is `DEEPSEEK_MODEL` (`deepseek-flash`, which DeepSeek points at its
  latest Flash), with thinking off for a fast first token.
- The `AI` binding reaches the `AI_GATEWAY_ID` gateway (`default`), so the
  Worker needs no gateway token. Requests skip the gateway's logs.
- Only the last 3 context turns are used, and text plus context is capped at
  `TRANSLATE_MAX_CHARS`.
- Each request counts 1 against its own budgets, kept apart from listening
  time: `*_TRANSLATIONS_PER_MINUTE` and `*_TRANSLATIONS_PER_DAY` per install,
  account, Pro subscription and IP, and `GLOBAL_TRANSLATIONS_PER_DAY`. A failed
  upstream call is refunded.

Set the key with `npx wrangler secret put DEEPSEEK_API_KEY`. Tests replace the
`AI` binding with a fake (`remoteBindings: false` in `vitest.config.ts`), so
they never reach Cloudflare.

## Lively Pro

Pro raises the daily budget to the `PRO_` limits. A caller is Pro if it sends
an active App Store or Google Play subscription or is signed in to an account
with `free_pro`.

### App Store subscriptions

The app sends its current StoreKit 2 transaction (`jwsRepresentation`) as
`Lively-Subscription` with each key request. `src/appstore.ts` checks it
without calling Apple:

1. The `x5c` chain: the intermediate must be signed by the copy of Apple Root
   CA - G3 in the source, not by whatever root the chain brings, and the leaf
   by the intermediate. Each must carry Apple's marker extension (leaf
   `1.2.840.113635.100.6.11.1`, intermediate `1.2.840.113635.100.6.2.1`), as
   Apple's own App Store Server Library requires, so other certificates under
   Apple's root, like developers' signing certificates, don't pass. Each must
   be valid at the transaction's `signedDate`.
2. The ES256 signature, with the leaf's key.
3. `bundleId` is `APP_BUNDLE_ID`, `productId` is in `PRO_PRODUCT_IDS`,
   `environment` is in `APP_STORE_ENVIRONMENTS`, `expiresDate` is in the
   future, there's no `revocationDate`, and the original transaction isn't in
   `revoked_subscriptions`.

A bad or expired transaction is ignored, and the caller gets the free plan. A
transaction can't be forged, but it can be copied, so Pro usage is charged to
`subscription:<hash of the original transaction ID>`, wherever it's used.
Like an account, a subscription isn't held to the per-IP daily budget, and its
hash is the `client_reference_id`.

`APP_STORE_ENVIRONMENTS` includes `Sandbox`, which is where TestFlight
purchases happen, for free. Xcode's local StoreKit testing signs with a
certificate of its own, so the broker never accepts those transactions.

Renewals are new transactions, which StoreKit delivers to the app. Refunds
and revocations come from App Store Server Notifications V2:

```
POST /v1/appstore/notifications   {"signedPayload": "..."}   → 200 {"ok": true}
```

The payload and its `signedTransactionInfo` are checked the same way. `REFUND`
and `REVOKE` add the original transaction ID to `revoked_subscriptions`;
`REFUND_REVERSED` removes it. Anything else, or another app's notification, is
acknowledged and ignored. In App Store Connect, set **App Information › App
Store Server Notifications** to `https://lively.ian.sh/v1/appstore/notifications`,
Version 2, for both Production and Sandbox.

### Google Play subscriptions

The Android app sells the same products (`PRO_PRODUCT_IDS`) through Play
Billing and sends its current Pro purchase's token as `Lively-Play-Purchase`
with each key request. It never sends `Lively-Subscription`. A token isn't
signed data, so `src/play.ts` asks Google about it, but only when there's no
valid App Store subscription:

1. It signs an RS256 JWT as the service account in the
   `GOOGLE_PLAY_SERVICE_ACCOUNT` secret and exchanges it at
   `https://oauth2.googleapis.com/token` for an `androidpublisher` access
   token, which it keeps until a minute before it expires.
2. It gets `purchases/subscriptionsv2/tokens/{token}` for `PLAY_PACKAGE_NAME`
   from the Google Play Developer API.
3. The purchase counts if `subscriptionState` is `ACTIVE`, `IN_GRACE_PERIOD`
   or `CANCELED` (cancelled but paid through), a line item's `productId` is in
   `PRO_PRODUCT_IDS` with an `expiryTime` in the future, and it isn't a
   `testPurchase` unless `PLAY_ALLOW_TEST_PURCHASES` is `true`.

Each answer is kept in memory for 5 minutes per token (but never past the
line item's expiry), bad tokens included, so a key every few minutes doesn't
ask Google every time. Google answering 400, 404 or 410 means a bad token. If
Google errors or can't be reached, the caller gets the plan it would have
without the purchase, and Google is asked again after 30 seconds. Refunds and
revocations expire the subscription at Google, so they take effect at the next
check.

A token can be copied too, so Pro usage is charged to
`subscription:<hash of "play:" + hash of the token>`, which can't collide with
an App Store original transaction ID. An upgrade or resubscription gets a new
token, and so a fresh daily budget.

`PLAY_ALLOW_TEST_PURCHASES` is `true` for now, like `Sandbox` for TestFlight:
license testers and internal testing tracks buy for free.

Without `GOOGLE_PLAY_SERVICE_ACCOUNT`, the header is ignored. To set it up once:

1. In Google Cloud, pick or create a project, enable the **Google Play Android
   Developer API**, and create a service account (IAM & Admin › Service
   Accounts) with no project roles. Under its Keys tab, add a JSON key.
2. In Play Console, go to **Users and permissions**, invite the service
   account's email, and grant it **View financial data, orders and
   cancellation survey responses** for Lively. It can take a while to work.
3. Store the key file's whole contents as the secret:

   ```bash
   npx wrangler secret put GOOGLE_PLAY_SERVICE_ACCOUNT < service-account.json
   ```

   Then delete the downloaded key file.

### Free Pro accounts

Accounts with `free_pro` get Pro without paying. Migration 0003 gives it to
every account that existed before Pro. To give it to someone, have them sign in
once, then:

```bash
npx wrangler d1 execute lively-key-broker --remote \
  --command "UPDATE users SET free_pro = 1 WHERE email = 'friend@example.com'"
```

Set it to 0 to take it away. The app rereads it at launch.

## Sign-in

Sign-in is optional, with a 6-digit code sent by email.

```
POST /v1/auth/email/start   {"email": "a@example.com"}
200 {"ok": true, "expires_in_seconds": 600}

POST /v1/auth/email/verify  {"email": "a@example.com", "code": "123456"}
200 {"token": "<43 chars>", "user": {"id": "<uuid>", "email": "a@example.com", "free_pro": false}}

GET  /v1/auth/me            Authorization: Bearer <token>   → {"user": {...}}
POST /v1/auth/logout        Authorization: Bearer <token>   → {"ok": true}
POST /v1/auth/delete        Authorization: Bearer <token>   → {"ok": true}
```

`user` is `{id, email, free_pro}`. Delete removes the account, all its sessions
and any pending code. Usage counters hold only a hash of the account ID and
expire within a day. A subscription isn't tied to an account, so it keeps
working.

| Variable | Default | Meaning |
|---|---|---|
| `EMAIL_FROM` | `login@x.ian.sh` | sender address |
| `CODE_TTL_SECONDS` | 600 | how long a code works |
| `CODE_MAX_ATTEMPTS` | 5 | guesses per code |
| `CODES_PER_EMAIL_PER_HOUR` | 5 | codes sent to one address per hour |
| `CODES_PER_EMAIL_PER_DAY` | 10 | codes sent to one address per UTC day |
| `CODES_PER_IP_PER_HOUR` | 20 | codes requested from one IP per hour |
| `SESSION_DAYS` | 365 | how long a session token lasts |

A new code replaces the last one, and a code works once. With the defaults,
someone guessing at an account gets 50 guesses a day, about a 1 in 20,000
chance. Emails are lowercased and trimmed; one email is one account. Codes are
stored as SHA-256 of the email and code, and sessions as SHA-256 of the token,
so a copy of the database can't sign anyone in.

Mail goes out through [Cloudflare Email
Service](https://developers.cloudflare.com/email-service/) via the
`send_email` binding `EMAIL`. Sending to any address needs the Workers Paid
plan, and `EMAIL_FROM`'s domain (`x.ian.sh`) must be onboarded under Email Service ›
Sending in the dashboard, which adds its SPF and DKIM records. `wrangler dev`
doesn't send: it logs each message and saves its text under `.wrangler/tmp/email/`.

Counters live in D1. Each request makes one batched, transactional upsert, so
concurrent requests can't both slip under a limit. Rejected and failed requests
are refunded. A cron job at :17 every hour deletes expired counters, codes and sessions.

## Pages

The Worker also serves the App Store's required pages: `/privacy`, `/support`
and `/terms`. Each gives `support@lively.ian.sh` as the contact. Mail to it
needs Cloudflare Email Routing on the `ian.sh` zone (Email › Email Routing ›
Routing rules), forwarding `support@lively.ian.sh` to a real inbox.

## Develop

```bash
npm install
cp .dev.vars.example .dev.vars        # then put a real SONIOX_API_KEY_US in it
npm run db:migrate:local
npm run dev                           # http://localhost:8787
npm test                              # vitest in workerd, Soniox mocked
npm run typecheck
```

App builds use the deployed broker. To try local changes in the simulator or
the Mac app, set the Debug `LIVELY_KEY_BROKER_URL` to `http://localhost:8787`
for the session, and don't commit it.

Cloudflare's bot check turns away some generic clients, such as Python's
`urllib` default user agent (error 1010). curl and the app get through. Set a
`User-Agent` in scripts.

## Deploy

The broker runs at **https://lively.ian.sh**, a Workers custom domain on the
`ian.sh` zone, on the Cloudflare account for ian@cautela.us (account
`1020dc9a8bd7a82cd0801975a100d3ee`). The D1 database `lively-key-broker` is in
WNAM. Smart Placement runs the Worker near D1 and Soniox's API, so a caller in
Asia makes one long round trip instead of one per upstream call.

### Automatic

`.github/workflows/deploy-key-broker.yml` runs the type check and tests on every
push and pull request that touches `Server/key-broker/`. On `main` it then
applies D1 migrations and runs `wrangler deploy`. It needs one repository
secret, `CLOUDFLARE_API_TOKEN`:

1. In the Cloudflare dashboard, go to My Profile › API Tokens › Create Token
   and use the **Edit Cloudflare Workers** template. Add **Account › D1 ›
   Edit**. Limit it to the ian@cautela.us account.
2. `gh secret set CLOUDFLARE_API_TOKEN --repo iangcarroll/lively` and paste
   it.

To deploy without a push, use Actions › Deploy key broker › Run workflow.

### By hand

```bash
cd Server/key-broker
npx wrangler login                   # as ian@cautela.us
npm run db:migrate                   # applies migrations/ to the remote D1
npm run deploy
```

To rotate a Soniox key, run `npx wrangler secret put SONIOX_API_KEY_US` (or
`_JP`). The deployed US key is still named `SONIOX_API_KEY`, which works until
`SONIOX_API_KEY_US` is set; delete it after. The keys aren't in the repo or in
CI, and the deploy workflow leaves them alone.

To set the broker up from scratch on another account, run `npx wrangler d1
create lively-key-broker`, then put the new `database_id` and `account_id` in
`wrangler.jsonc`. Next run `npm run db:migrate`, set the secret, and deploy.

The app reads the URL from `LIVELY_KEY_BROKER_URL` in `Lively.xcodeproj`
(target › Build Settings), for both Debug and Release.

### China

`*.workers.dev` is often blocked or slow in mainland China, so the app uses the
custom domain (`routes` in `wrangler.jsonc`). Once a route is set, the
`workers.dev` URL is turned off. Whether `ian.sh` is reachable from mainland
China hasn't been tested.

In the Soniox console, set a budget on the account that owns the key. It's the
last backstop if the limits above are set too loosely.
