# Lively

Live English ⇄ Chinese conversation translation for iOS and macOS.

Either person speaks whenever they want. The speech engine detects the language
and the turn boundaries, and each turn is translated as it's spoken.

## Engines

Pick one in Settings › Engine. Each has its own API key, stored in the Keychain.

| Engine | How it works | Key |
|---|---|---|
| **Voxtral + Mistral** (default) | `voxtral-mini-transcribe-realtime-3` transcribes and detects turns, then a Mistral chat model translates each turn | console.mistral.ai |
| **Soniox** | `stt-rt-v5` transcribes and translates both ways (`two_way`, en ⇄ zh) in one stream, so there's no second request per turn | console.soniox.com |

Soniox only outputs Simplified Chinese. When Settings › Chinese is 繁體, Lively
converts its output on the device.

## Run

Open `Lively.xcodeproj` and run the **Lively** scheme on an iPhone, iPad
simulator, or **My Mac**. Choose an engine and add its API key in Settings.

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

### Soniox API keys on devices

The app stores a long-lived Soniox key on the device, the same as the Mistral key.
For a shipped app, Soniox supports temporary keys: a backend holding the real
key calls `POST https://api.soniox.com/v1/auth/temporary-api-key` with
`usage_type: "transcribe_websocket"` and `expires_in_seconds` (1–3600), plus
optional `single_use` and `max_session_duration_seconds`, and hands the result to
the app. When a temporary key expires mid-session, Soniox returns 403. Lively has
no backend, so this isn't wired up. Adding it means fetching a key in
`SonioxTranscriber.makeRequest()` before each connection.

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
- A rejected key stops listening and says which provider's key to fix.

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
