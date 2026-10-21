# Lively

Live English ⇄ Chinese conversation translation for iOS and macOS.

Either person speaks whenever they want. The speech engine detects the language
and the turn boundaries, and each turn is translated as it's spoken.

## Engines

Pick one in Settings › Engine. Soniox gets temporary keys from Lively's key
broker, so it needs no setup. Voxtral needs your own Mistral key. Keys entered in
Settings are stored in the Keychain.

| Engine | How it works | Key |
|---|---|---|
| **Soniox** (default) | `stt-rt-v5` transcribes and translates both ways (`two_way`, en ⇄ zh) in one stream, so there's no second request per turn | from the [key broker](#soniox-keys), or your own from console.soniox.com |
| **Voxtral + Mistral** | `voxtral-mini-transcribe-realtime-3` transcribes and detects turns, then a Mistral chat model translates each turn | console.mistral.ai |

Soniox is the default because it won the [benchmark](Tools/probe/RESULTS.md).

Soniox only outputs Simplified Chinese. When Settings › Chinese is 繁體, Lively
converts its output on the device.

## Run

Open `Lively.xcodeproj` and run the **Lively** scheme on an iPhone, iPad
simulator, or **My Mac**.

Soniox works without any setup. Builds get temporary keys from the deployed
broker at `https://lively-key-broker.ian-102.workers.dev` (see
[Server/key-broker](Server/key-broker/README.md)). For Voxtral, add a Mistral
key in Settings.

To try the UI without a key, add the launch argument `-LivelyDemo YES` and tap the
mic. It plays a scripted conversation through the real turn and translation logic.

## How it works

| Stage | Where |
|---|---|
| Mic → 16 kHz PCM16, 80 ms chunks | `Audio/MicCapture.swift` |
| Engine registry: names, keys, which settings apply, how to build each pipeline | `Model/SpeechProvider.swift` |
| Engine interface and events | `Networking/SpeechEngine.swift` |
| Reconnects, pings, audio backlog, shared by every engine | `Networking/ResilientSocket.swift` |
| Voxtral: WebSocket to `voxtral-mini-transcribe-realtime-3`, language auto-detected, turn detection on | `Networking/RealtimeTranscriber.swift` |
| Voxtral: streaming translation over Mistral chat completions | `Networking/Translator.swift` |
| Soniox: WebSocket to `stt-rt-v5` with two-way translation and endpoint detection | `Networking/SonioxTranscriber.swift` |
| Soniox: temporary keys from the broker, with one spare kept ready | `Networking/SonioxKeyProvider.swift` |
| Key broker: Cloudflare Worker that mints temporary Soniox keys | `Server/key-broker/` |
| Turns, utterances, translation scheduling | `Model/ConversationStore.swift` |

Engines report events in one of two ways:

- **Transcribe only** (Voxtral). Text deltas and turn boundaries come from the
  engine, and `ConversationStore` translates each turn with a
  `TranslationService`.
- **Transcribe and translate** (Soniox). The engine reports whole segments with
  their translation. A segment ends at Soniox's `<end>` endpoint token, and its
  translation can keep arriving after that. Non-final tokens are shown but
  replaced by the next response.

Either way, a turn that goes 3 s without any events is closed.

### Adding an engine

1. Write a `SpeechEngine`. If it streams over a WebSocket, implement
   `SocketDialect` and let `ResilientSocket` handle the connection.
2. Next to it, declare a `SpeechProvider` with its `ProviderCredential`s and the
   `ProviderOption`s that apply.
3. Add it to `SpeechProvider.all`.

Settings, Keychain storage and the conversation pipeline pick it up from there.

### Soniox keys

The app never ships a long-lived Soniox key. It gets one from Lively's key
broker, a Cloudflare Worker in `Server/key-broker/`:

1. On first launch the app makes a random install ID and keeps it in the
   Keychain.
2. `SonioxKeyProvider` posts it to the broker's `/v1/soniox/key`. The broker
   checks its rate limits and denylist, then calls Soniox's
   `POST /v1/auth/temporary-api-key` with the real key and returns a
   single-use key that expires in 60 s.
3. `SonioxTranscriber.makeRequest()` takes a key for each connection and
   opens the WebSocket to Soniox directly. Audio never goes through the broker.
4. While listening, the provider keeps one spare key and replaces it about
   every 50 s, so a reconnect on a flaky network doesn't wait on the broker.
   Taking the spare starts fetching the next one.
5. Soniox rejects an expired or reused temporary key with `error_code` 401 in
   its first message. The transcriber then reconnects with a fresh key. After 3
   rejections in a row it gives up and says so, instead of blaming a key in
   Settings.

The broker URL comes from the `LIVELY_KEY_BROKER_URL` build setting, through
the `LivelyKeyBrokerURL` key in `Config/Lively-Info.plist`, and points at the
deployed Worker for Debug and Release. With no URL, Soniox needs a key in
Settings. A key entered in Settings always overrides the broker, for
development. Pushes to `main` that touch `Server/key-broker/` run its tests and
deploy it through GitHub Actions.

Mistral has no temporary keys, so Voxtral is a developer option and always needs
a key in Settings.

To keep latency low:

- Soniox translates in the same stream as transcription, with endpoint detection
  at a 1 s maximum delay.
- Voxtral's streaming delay defaults to 240 ms ("Fastest" in Settings).
- With Voxtral, translation starts on `turn.eager_end`, before the turn is
  confirmed.
- While someone is still talking, translation is throttled rather than
  debounced, so long sentences keep updating.
- The first translation of a turn streams token by token.

On a bad network (all engines, via `ResilientSocket`):

- Audio keeps recording while the socket is down, with up to 20 s held in a
  backlog that is replayed on reconnect.
- Reconnects use jittered backoff, and a ping every 4 s detects dead sockets.
- `NWPathMonitor` triggers an immediate retry when the network comes back.
- Mistral translations wait for the network, then retry with backoff.
- A rejected key stops listening and says which provider's key to fix. A
  rejected temporary Soniox key just gets replaced.
- Broker hiccups are retried with the same backoff. Daily limits and denials
  stop listening with the broker's message.

## Layouts

- **Phone** (default): face-to-face. Lay the phone flat between two people. The
  top half is upside down for the person opposite and the bottom half faces you.
  Each half shows only its reader's language, and the mic sits in the middle
  where either person can reach it. A chat-style transcript is available from
  the ••• menu.
- **iPad, Mac, landscape, unfolded Duo** (≥ 640 pt wide): side-by-side English
  and 中文 columns.

English is always indigo and Chinese always vermilion, in both light and dark
mode.
