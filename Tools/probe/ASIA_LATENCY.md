# Soniox latency for users in Asia: 2026-10-20

**Short answer.** Every Lively session today goes to Soniox's US region. For users in East and Southeast Asia, that adds roughly 0.15–0.25 s to each translation, and about 0.3–0.5 s to every connect and reconnect. Translations already arrive a median 1.5 s before the speaker finishes, so the steady-state cost is noticeable but not severe. The latest-arriving segment of a turn goes from about +0.35 s to about +0.5–0.6 s.

Two things hurt more:

- **Reconnects on bad networks.** Each reconnect costs several round trips.
- **Backlog replay.** Soniox works through replayed audio at only about 1.15× real time. A long dropout therefore leaves every later translation late for minutes. This was measured; see §3.

Soniox has a Japan region. Moving Asian users there removes most of the RTT. It needs a second Soniox project and region-aware keys in the broker.

Each number below is labelled **measured** (from this Mac) or **estimated** (from public RTT tables).

## 1. What Soniox offers (from Soniox docs)

- **Four regions.** Each has its own hostnames ([Data residency](https://soniox.com/docs/data-residency)):

  | Region | API (temp keys) | Real-time STT WebSocket |
  |---|---|---|
  | United States (what Lively uses) | `api.soniox.com` | `stt-rt.soniox.com` |
  | European Union | `api.eu.soniox.com` | `stt-rt.eu.soniox.com` |
  | **Japan** | `api.jp.soniox.com` | `stt-rt.jp.soniox.com` |
  | India | `api.in.soniox.com` | `stt-rt.in.soniox.com` |

- **Regions are per project.** Data residency is set per project, and "each project receives region-specific API keys". Requests with a project's key are "handled fully within the selected region". To use a region, you request it under Console → Security & compliance → Region access. It "stays pending until it is approved". Every region is listed as "Full API supported". The page does not mention per-region pricing, model availability, latency, or China.
- **Temporary keys.** The docs for [create temporary API key](https://soniox.com/docs/stt/api-reference/auth/create_temporary_api_key) and the [temporary keys guide](https://soniox.com/docs/guides/temporary-api-keys) show only `api.soniox.com` and say nothing about regions. I tested this directly (**measured**, US project key):
  - A US key on `stt-rt.jp.soniox.com` or `stt-rt.eu.soniox.com`: in-band `error_code 401`.
  - A temp key minted at `api.soniox.com`, used on `stt-rt.jp.soniox.com`: **401**.
  - Minting at `api.jp.soniox.com` with the US key: HTTP **401**.
  - The same kind of temp key on `stt-rt.soniox.com`: works.

  **Temporary keys are region-scoped.** A JP session needs a JP project key, minted at `api.jp.soniox.com`.
- **Reconnects** ([WebSocket API](https://soniox.com/docs/stt/api-reference/websocket-api)). There is no session resume. A dropped stream means opening a new WebSocket and starting over. `503` means "retry with backoff", and `408`/`500` are retryable. An idle socket needs a `keepalive` control message at least every 40 s, or it is closed with status 1001. Idle sockets count against the connection limit.

## 2. Measurements from this Mac (Los Angeles, T-Mobile; **measured**)

**Where the endpoints live (DNS).**

- All four `stt-rt.*` hosts resolve to the same Cloudflare anycast IPs, `104.18.22.191` and `104.18.23.191`. The edge was LAX (`cf-ray …-LAX`).
- The `api.*` hosts are AWS ELBs: `api.soniox.com` is in **us-east-1**, and `api.jp.soniox.com` is in **ap-northeast-1 (Tokyo)**.
- The TLS session terminates at the nearest Cloudflare edge, and audio travels on to the regional origin.

**Edge vs origin (8 HTTPS GETs per host).** RTT to the Cloudflare edge is 37 ms (ping). The time from finished TLS to the first byte of the origin's 404, as a median, was:

| Host | Post-TLS TTFB | Minus edge RTT ≈ edge→origin |
|---|---|---|
| `stt-rt.soniox.com` | 107 ms | ~70 ms (LA→Virginia is 59 ms) |
| `stt-rt.jp.soniox.com` | 156 ms | ~120 ms (LA→Tokyo is 106 ms) |
| `stt-rt.eu.soniox.com` | 219 ms | ~180 ms |

The ordering fits US = Virginia and JP = Tokyo. It also shows that this unauthenticated GET reaches the regional origin, which makes it a usable probe (§5). The origin locations are inferred, not documented.

**Connect and time to first token** (6 sessions, `stt-rt.soniox.com`, the same config as the app; scratch script):

| | Median | Range |
|---|---|---|
| WebSocket open (DNS + TCP + TLS + upgrade) | 0.45 s | 0.39–0.80 s |
| First server message after config | 0.11–0.15 s | |
| First token after speech onset | 0.97 s | 0.95–0.99 s |
| First final translation after speech onset (turn 0) | 2.16 s | 2.15–2.17 s |

**End of speech → translation** (`soniox_probe.py 1000`, the 10-turn conversation): connected in 0.38 s, 10/10 translated, 0 leaks. Median −1.52 s, worst +0.34 s. That matches `RESULTS.md`. Most of the latency comes from the model, which finalizes per clause; the network from LA adds only about 70 ms of it.

**Server message cadence while audio flows** (3 runs): the gap between messages had a median of 112–146 ms, p95 0.37–0.66 s, and max 1.03–1.12 s.

## 3. Backlog replay is slow (**measured**)

`ResilientSocket` keeps up to 20 s of audio while disconnected and replays it all at once on reconnect. I tested this by bursting the first 10 s or 20 s of the conversation at once (sent in under 0.4 s), then continuing in real time.

- The translation and final-token timestamps were identical for the 10 s and 20 s bursts: 1.12 / 1.71 / 3.97 s for both.
- With a 20 s burst, final source tokens for audio up to 5 / 10 / 15 / 20 s arrived at 3.97 / 7.24 / 11.72 / 17.49 s after reconnect.

So Soniox processes replayed audio at about 1.15–1.4× real time, not instantly. After a 20 s outage, translations lag about 17 s behind live speech. Live audio keeps arriving, so the lag shrinks only about 0.15 s per second, which is roughly two minutes to catch up. On flaky networks this is the largest latency problem, bigger than any region choice. Two runs (one at 10 s and one at 20 s, plus the 0.04 s baseline) is a small sample, so treat 1.15× as approximate.

## 4. Estimated extra delay from Asia (**estimated**)

Each translation pays about one client→origin RTT: audio goes up, tokens come back. The table uses WonderNetwork averages between datacenters ([Tokyo](https://wondernetwork.com/pings/Tokyo), [Washington](https://wondernetwork.com/pings/Washington), [Singapore](https://wondernetwork.com/pings/Singapore), fetched 2026-10-20). Mobile users add 20–60 ms of last-mile delay, and the Cloudflare edge can change routes. The US origin is assumed to be near Washington and the JP origin in Tokyo, per §2.

| User in | → US region | → JP region | Note |
|---|---|---|---|
| Tokyo / Osaka | 149 ms | ~8 ms | |
| Seoul | 181 | 31 | |
| Taipei | 188 | 30 | |
| Hong Kong | 200 | 57 | |
| Singapore | 213 | 65 | India region: 53 ms |
| Bangkok | 231 | 80 | |
| Jakarta | 225 | 81 | |
| Ho Chi Minh City | 248 | 94 | |
| Manila | 218 | 149 | Routing-dependent; Manila→Singapore is 29 ms |
| Shanghai | 222 | 164 | Cross-border; varies by carrier, often lossy |

- **Per translation:** moving East and Southeast Asia to JP saves about 0.12–0.19 s.
- **Per connect:** TCP and TLS end at the local edge. The WebSocket upgrade and the first config→response each need a trip to the origin, so a US-region connect costs about +0.3–0.4 s versus JP. Lively reconnects on every network blip, so this adds up.

## 5. Mainland China

- **`workers.dev` is blocked.** GreatFire reports "100% of the last 5 conclusive tests failed in mainland China" (last test 2026-10-15, [greatfire.org/workers.dev](https://en.greatfire.org/workers.dev)). The key broker **must** get a custom domain before launch.
- **Cloudflare without the China Network.** Content served from outside China "faces significant latency and reliability issues". The China Network is Enterprise-only, needs an ICP filing, and runs on JD Cloud ([Cloudflare docs](https://developers.cloudflare.com/china-network/)). Even on a custom domain, the broker and `stt-rt.*` (also on Cloudflare) will be served to mainland users from outside the mainland: reachable, but slow and lossy.
- **`soniox.com` is untested on GreatFire.** I could not test reachability from a mainland vantage point here. **Not measured.** Before relying on it, run this from a mainland host (VPS, or a tester on China Mobile, China Unicom and China Telecom):
  ```bash
  for h in stt-rt.soniox.com stt-rt.jp.soniox.com api.soniox.com api.jp.soniox.com <broker-domain>; do curl -s -o /dev/null -w "$h tcp %{time_connect} tls %{time_appconnect} ttfb %{time_starttransfer}\n" https://$h/; done
  ```
- **Which region for China.** Public tables favour JP (Shanghai→Tokyo 164 ms vs →Washington 222 ms), but carrier routing decides in practice. Pick per user by measuring, which is what the region prober in §6 does. On these links, packet loss and reconnect cost matter more than RTT, so the work in §6.3 matters most for China.

## 6. Recommendations (proposed; no app code changed)

### 6.1 Add the Japan region (largest win for East and Southeast Asia)
**Implemented** in the broker and app. Step 1, the Japan project and `SONIOX_API_KEY_JP`, is still to do; until then the broker offers only the US.

1. In the Soniox Console, request **Japan** region access and create a JP project. Approval is manual.
2. Broker (`Server/key-broker/src/broker.ts`):
   - Store one master key per region (`SONIOX_API_KEY_US`, `SONIOX_API_KEY_JP`).
   - Accept an optional `Lively-Region` header, checked against an allowlist. Otherwise pick a default from `request.cf.country`, e.g. JP/KR/TW/HK/MO/CN/SG/MY/TH/VN/PH/ID → `jp`.
   - Mint at `https://api.<region>.soniox.com/v1/auth/temporary-api-key`.
   - Return `region` and `websocket_url` with the key.
3. App:
   - Replace the hard-coded `SonioxTranscriber.endpoint` (`Lively/Networking/SonioxTranscriber.swift:36`) with the URL that comes with the key.
   - `SonioxKeyProvider.TemporaryKey` carries its region. Since keys are region-scoped, a spare minted for one region is useless in another. Drop the spare when the preferred region changes.
4. Optionally add India later for South Asia. Singapore is 53 ms from Mumbai vs 65 ms from Tokyo, which is too small a gap to justify a third project now.

### 6.2 Periodic best-region probing (your suggestion; fits well)
**Implemented** in `Lively/Networking/RegionProber.swift`, except persisting the choice per network. It keeps one choice for all networks, and a path change triggers a fresh probe.

- **Probe.** Send an unauthenticated `GET https://stt-rt.<region>.soniox.com/` per candidate region. It returns a 404 from the regional origin through Cloudflare, which is the same path audio takes (§2). Make 3 requests on one HTTP/2 connection and take the min of the last two, which excludes handshakes. It is cheap, uses no key, and costs nothing at Soniox.
- **When.** At launch and on foreground, on an `NWPathMonitor` interface or path change, every ~10 min while listening, and after 2 consecutive connect failures. Never probe on a timer while idle in the background.
- **Choosing.** Keep a per-region EWMA RTT and success rate, and score as RTT plus a failure penalty. Switch only when a region is clearly better (≥25% **and** ≥40 ms) to avoid flapping. Persist the choice per network (SSID or cellular) so a reconnect starts warm.
- **Applying.** The choice applies only to the **next** connection, sent to the broker as `Lively-Region`. Never tear down a healthy socket just to change region. Exception: make-before-break at an utterance boundary (§6.3).
- **Fallback.** If the chosen region fails 2–3 connects in a row, reconnect to the next-best region. This requires fetching a key for that region.

### 6.3 Unstable networks (your second point; most of the remaining latency is here)
1. **Detect stalls faster.**
   - Today a dead socket is found by a 4 s ping with a 5 s timeout, up to about 9 s.
   - Soniox sends a message about every 0.12 s while audio flows (p95 ≤ 0.66 s, max ~1.1 s, §2).
   - Add a watchdog in `ResilientSocket`: if audio has been sent but no message has arrived for **2.5 s**, reconnect. This would cut detection to about 2.5 s.
   - Lower `request.timeoutInterval` from 10 s to about 5 s.
2. **Change backlog replay (§3).** Replaying 20 s at once creates minutes of lag.
   - Trim silence out of the backlog with an energy/VAD gate. Most outage audio is silence or the other side listening.
   - If more than ~3 s of speech remains, send it on a **separate catch-up socket** while live audio goes to the fresh socket right away. Show catch-up translations as late, and drop them if they finish more than ~30 s after the speech.
   - Billing is per audio-second, so the second socket adds no cost, just one more concurrent connection.
   - The simpler fallback is to cap the replay at ~5 s and drop the rest.
3. **Make-before-break on path change.** When `NWPathMonitor` reports a new usable interface (for example Wi-Fi → cellular):
   - Open a second socket using the spare key.
   - Move audio to it at the next `<end>`.
   - Send `""` to the old socket so it finishes the last utterance.

   This avoids losing the in-flight utterance on handoffs, which are common when walking with a phone.
4. **Keep the spare key alive through broker outages.**
   - Today keys live 60 s and refresh about every 50 s, so a broker outage longer than ~1 min means a reconnect also needs the broker.
   - Mint with `expires_in_seconds: 300`, still `single_use` and still with `max_session_duration_seconds`. The spare then survives 5 min of broker trouble, which is likely on mainland networks reaching Cloudflare from outside.
   - It also cuts broker traffic 5×.
5. **Pre-connect.** Open the socket (and send config) when the conversation screen appears, not on the first speech. Send `{"type":"keepalive"}` every ≤40 s while no audio flows. This removes the ~0.45–0.8 s open (more from Asia) from the first utterance. The cost is one connection slot per open screen.
6. **Keep current error handling.** It already matches Soniox's guidance: 408/413/429/5xx → fresh session with backoff; 401/403 → new key. Use a longer backoff on `429 max_concurrent_connections_reached`, so a catch-up socket or standby socket can't loop against the limit.

### 6.4 Broker domain
Deploy the broker on a custom domain (a Cloudflare route on a domain you own), never `*.workers.dev`. `workers.dev` is blocked in mainland China (§5). The China Network (ICP and Enterprise) is not worth it for a 60–300 s key fetch that is off the hot path.

## Reproducing
- `soniox_probe.py` is unchanged; I ran it as `python soniox_probe.py 1000`.
- The regional key checks, connect/TTFT loop and burst-replay test were one-off scratch scripts, not committed. Each one opens `wss://stt-rt[.<region>].soniox.com/transcribe-websocket` with the same config as `soniox_probe.py`. The burst test sends the first N seconds at once, then real time.
- HTTPS timings came from `curl -w '%{time_connect} %{time_appconnect} %{time_starttransfer}'` against each host's `/`.

## 7. §6.3 implemented (2026-10-20)

Implemented: 6.3.1 (stall watchdog), 6.3.2 (catch-up socket), 6.3.3 (make-before-break), 6.3.4 (300 s keys) and the 429 backoff from 6.3.6. Pre-connect (6.3.5) is not done.

- **Stall watchdog.** `ResilientSocket` reconnects when audio has gone out and nothing has come back for `SocketDialect.stallTimeout` (2.5 s for Soniox, off for Voxtral). The handshake timeout is now 5 s.
- **Backlog.** On reconnect, an energy gate trims silence out of the backlog (`ResilientSocket.trimSilence`). It keeps 240 ms of padding and pauses up to 800 ms. More than 3 s of remaining speech goes to a separate catch-up session, which replays it, ends, and is dropped after 30 s. Live audio goes straight to the fresh session. Catch-up utterances are inserted where the dropout began and labelled "Caught up after a dropout". Engines without side streams (Voxtral) replay at most the last 5 s.
- **Make-before-break.** `ConversationStore` reports a change of the network interface type. The socket then opens a standby session and moves audio to it at the next `<end>`, or after 8 s, or at once if no utterance is open. The old session gets `""` and 10 s to finish. If the old socket dies first, the standby takes over immediately.
- **Keys.** The broker mints 300 s keys (`KEY_TTL_SECONDS`), still single-use. The app replaces its spare at 80% of the key's life (240 s). `KEY_CHARGE_SECONDS` is 120. See the broker README.
- **429.** Soniox `429` (including `max_concurrent_connections_reached`) and HTTP 429 at the handshake back off from 5 s up to 30 s, instead of 0.3 s up to 6 s. A catch-up or standby session that hits any error is dropped, never retried.

**Dropout probe** (`python dropout_probe.py 11.5 9`, **measured**, LA). The connection is cut 11.5 s into the conversation for 9 s. The table shows final translation time minus end of speech for the live turns after recovery:

| Strategy | Mean | Worst | Turns lost |
|---|---|---|---|
| no dropout | +0.28 s | +0.36 s | — |
| replay all (old) | +5.58 s | +6.41 s | 0 |
| **catch-up socket (new)** | **+0.26 s** | **+0.60 s** | 0 |
| trim + cap 5 s | +1.44 s | +2.33 s | 1 |

The held turns themselves arrived +6–8 s late with both replay and catch-up. That is expected: they could not be sent sooner.

**In the app** (Debug builds only, iPhone 18 Pro simulator):
- `-LivelyAudioFile PATH` feeds a WAV in place of the mic, with no sound.
- `-LivelyDropout "12,9"` blackholes the sockets for 9 s, starting 12 s in.
- `-LivelyPathChange 34` reports an interface change at 34 s.

Watch the result with `xcrun simctl spawn booted log stream --level debug --predicate 'subsystem == "aero.seats.lively"'`. With all three: the stall was detected 2.8 s into the dropout. 8.3 s of held speech went to a catch-up session that finished in 5.8 s. The path change handed over to a new session 2 s later, and the old one drained in 0.1 s.
