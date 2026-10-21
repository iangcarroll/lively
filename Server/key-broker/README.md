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
                 "jp": "wss://stt-rt.jp.soniox.com/transcribe-websocket"}}
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

Callers are anonymous. The app makes up a random UUID on first launch, keeps it
in the Keychain, and sends it as `Lively-Install-ID`. There's no App Attest or
sign-in, so anyone who copies the request can get keys. These limits cap what
that costs:

| Variable | Default | Limit |
|---|---|---|
| `PER_INSTALL_KEYS_PER_MINUTE` | 6 | keys per install per minute |
| `PER_INSTALL_MINUTES_PER_DAY` | 240 | listening minutes per install per UTC day |
| `PER_IP_KEYS_PER_MINUTE` | 30 | keys per IP per minute (IPv6 by /64) |
| `PER_IP_MINUTES_PER_DAY` | 1440 | listening minutes per IP per UTC day |
| `GLOBAL_KEYS_PER_DAY` | 100000 | keys for everyone per UTC day |
| `KEY_CHARGE_SECONDS` | 120 | listening time charged per key |
| `DENYLIST` | empty | comma-separated install hashes to refuse |

Listening time is estimated from keys. Keys live 5 minutes, so the app's
spare key outlasts a few minutes of broker trouble (common on mainland China
networks), and the app replaces it a minute before it expires, about every
240 s. Each key counts as 120 s: steady listening is undercounted about 2×,
but each reconnect, catch-up or handover session on a flaky network also
takes a key, and those shouldn't use up a day's budget. A client that skips the
refresh and holds one session open is still bounded, because each key's
`max_session_duration_seconds` is capped at what's left of the day's budget.

To cut off one install without a redeploy, add its hash (the
`client_reference_id` in Soniox's usage logs) to the D1 table:

```bash
npx wrangler d1 execute lively-key-broker --remote \
  --command "INSERT INTO denylist (install_hash, reason) VALUES ('<hash>', 'abuse')"
```

Change limits in `wrangler.jsonc` → `vars`, then deploy, or edit them in the
dashboard under Settings › Variables.

Errors are JSON `{error, message}`. A per-minute 429 carries a short
`Retry-After`, and the app retries it. A daily 429 (`Retry-After` over 60 s),
403 (denied) and 503 (global cap) stop listening and show `message`.

Counters live in D1. Each request makes one batched, transactional upsert, so
concurrent requests can't both slip under a limit. Rejected and failed requests
are refunded. A cron job at :17 every hour deletes expired counters.

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
