# Lively

Live English ⇄ Chinese conversation translation for iOS and macOS, built on
Mistral's Voxtral 3 realtime transcription.

Either person speaks whenever they want. Voxtral detects the language and the
turn boundaries, and each turn is translated as it's spoken.

## Run

Open `Lively.xcodeproj` and run the **Lively** scheme on an iPhone, iPad
simulator, or **My Mac**. Add a Mistral API key in Settings (it's stored in the
Keychain).

To try the UI without a key, add the launch argument `-LivelyDemo YES` and tap the
mic. It plays a scripted conversation through the real turn and translation logic.

## How it works

| Stage | Where |
|---|---|
| Mic → 16 kHz PCM16, 80 ms chunks | `Audio/MicCapture.swift` |
| WebSocket to `voxtral-mini-transcribe-realtime-3`, language auto-detected, turn detection on | `Networking/RealtimeTranscriber.swift` |
| Turns, language detection, translation scheduling | `Model/ConversationStore.swift` |
| Streaming translation over Mistral chat completions | `Networking/Translator.swift` |

To keep latency low:

- The streaming delay defaults to 240 ms ("Fastest" in Settings).
- Translation starts on `turn.eager_end`, before the turn is confirmed.
- While someone is still talking, translation is throttled rather than
  debounced, so long sentences keep updating.
- The first translation of a turn streams token by token.

On a bad network:

- Audio keeps recording while the socket is down, with up to 20 s held in a
  backlog that is replayed on reconnect.
- Reconnects use jittered backoff, and a ping every 4 s detects dead sockets.
- `NWPathMonitor` triggers an immediate retry when the network comes back.
- Translations wait for the network, then retry with backoff.

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
