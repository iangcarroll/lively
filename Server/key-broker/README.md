# Lively key broker

A Cloudflare Worker that holds Lively's real Soniox API key and gives the app
short-lived, single-use temporary keys. The app connects to Soniox directly
with them, so audio never passes through the Worker.

```
POST /v1/soniox/key
Lively-Install-ID: 3F2C9A3E-6B1D-4C55-9A0E-2D7E8F1B4C6A

200 {"api_key": "...", "expires_at": "2026-10-21T01:00:34.125Z",
     "expires_in_seconds": 60, "max_session_seconds": 7200}
```

For each request the Worker calls Soniox's
`POST https://api.soniox.com/v1/auth/temporary-api-key` with:

| Field | Value |
|---|---|
| `usage_type` | `transcribe_websocket` |
| `expires_in_seconds` | `KEY_TTL_SECONDS` (60) |
| `single_use` | `true` |
| `max_session_duration_seconds` | `MAX_SESSION_SECONDS` (7200), or less near the day's limit |
| `client_reference_id` | first 128 bits of SHA-256 of the install ID, hex |

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
| `KEY_CHARGE_SECONDS` | 50 | listening time charged per key |
| `DENYLIST` | empty | comma-separated install hashes to refuse |

Listening time is estimated from keys. While listening, the app replaces its
spare key every ~50 s, so each key counts as 50 s. A client that skips the
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
cp .dev.vars.example .dev.vars        # then put a real SONIOX_API_KEY in it
npm run db:migrate:local
npm run dev                           # http://localhost:8787
npm test                              # vitest in workerd, Soniox mocked
npm run typecheck
```

Debug builds of the app use `http://localhost:8787` as the broker, so the
simulator and the Mac app work against `npm run dev`. A physical device can't
reach your Mac's localhost. Enter a Soniox key in Settings, or point
`LIVELY_KEY_BROKER_URL` at a deployed Worker.

## Deploy

Use the Cloudflare account for **ian@cautela.us**. None of this has been run
yet.

```bash
cd Server/key-broker
npm install
npx wrangler login                   # sign in as ian@cautela.us
npx wrangler whoami                  # check the account
npx wrangler d1 create lively-key-broker
# Paste the printed database_id into wrangler.jsonc → d1_databases[0].database_id
npm run db:migrate                   # applies migrations/ to the remote D1
npx wrangler secret put SONIOX_API_KEY
npm run deploy
```

If the login can see more than one account, add `"account_id"` to
`wrangler.jsonc`.

`wrangler deploy` prints the URL, for example
`https://lively-key-broker.<subdomain>.workers.dev`. Check it:

```bash
curl -X POST -H "Lively-Install-ID: $(uuidgen)" https://lively-key-broker.<subdomain>.workers.dev/v1/soniox/key
```

Then set `LIVELY_KEY_BROKER_URL` for the Release configuration in
`Lively.xcodeproj` (target › Build Settings, currently empty) and archive. If
it's empty, Release builds need a Soniox key in Settings, as before.

In the Soniox console, set a budget on the account that owns the key. It's the
last backstop if the limits above are set too loosely.
