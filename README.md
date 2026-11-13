# Lively

Live English ⇄ Chinese conversation translation for iOS, macOS and Android.

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
| **On-device** (iOS/macOS) | Apple's Speech and Translation frameworks run on this device. No key, and no audio leaves the device | none |

Soniox is the default because it won the [benchmark](Tools/probe/RESULTS.md).

Soniox and Voxtral listen through **HybridSpeechEngine**: tapping the mic starts
the on-device recognizer immediately, so hearing and translating work while the
server session connects. The audio heard during that wait is kept in a short
buffer and replayed to the server when it comes online, then the provisional
on-device turns are replaced by the server's more accurate transcript. If the
server never arrives — or drops mid-conversation — the on-device recognizer
carries the conversation when its models are installed. Prepare both speech and
translation in **Settings › Offline Languages** before going offline. On-device listening is iOS/macOS
only; Android keeps ML Kit for typed text (see
[android/README.md](android/README.md)).

Tap the mic to start and stop listening, or hold it to listen only while it's
pressed, like a walkie-talkie: letting go ends the turn and stops the mic.

In the iOS and macOS transcript, the listening prompt stays above the mic
after the conversation starts, in both languages. It tells the next person
they can speak without pressing anything. The mic is labeled **Stop** while
active and **Start** while off; connecting and offline states show their own
messages instead of claiming to be listening.

When speaking isn't practical, the keyboard button opens a text field. Typed
lines go to DeepSeek through the key broker, falling back to on-device
translation (Apple's Translation framework; ML Kit on Android). Voxtral uses its
own Mistral translator for them.

## Offline conversations (iOS / macOS)

Open **Settings › Offline Languages**, then **Download languages** while online.
The screen checks the full speech models for both conversation languages and
translation models in both directions. Unsupported languages are marked for the
current device. Change the pair in Settings to prepare another pair; Apple's
speech storage limit may require releasing an unused language first.

Choose **Use on-device translation** to keep recognition and translation local,
even while connected. Before each person speaks, choose their language in the
**Who's speaking?** selector above the conversation. Local recognition uses that
language explicitly; online cloud recognition still detects both languages.
Typed text, edits, and text read from photos also use local translation in this
mode or when the network is unavailable, without waiting for a cloud request.
Missing models produce download guidance instead of starting a download while
listening. When a cloud conversation loses its connection, downloaded local
models take over immediately; the cloud provider reconnects when online again.

Spoken output is selected separately in **Settings › Speech-to-Speech › Spoken
voice**. **Original voice · online** (Soniox) is the default: it needs internet
and sends translated text to Soniox, even when recognition and text translation
run on-device. With that choice, offline translations remain visible while
spoken output pauses. **Downloaded voices · offline** use the local Kokoro model
after an explicit download; they don't send text to a speech service or fall
back to cloud or Apple system voices. Both choices use the same
headphone/speaker routing and microphone echo gating. The app doesn't promise
that every online language is available offline.

Open **Settings › Offline Voice Library** to browse the integrated Kokoro v1.0
catalog: **54 presets across 8 languages** — English (American and British),
French, Hindi, Italian, Japanese, Mandarin Chinese, Brazilian Portuguese, and
Spanish. Japanese has five presets: Alpha, Gongitsune, Nezumi, Tebukuro, and Kumo.
Use the language filter or search to find them. One shared **92,022,138-byte
download (about 92 MB)** installs the model and every preset; selecting more
voices doesn't download another model.

Choose one voice per language. The selection is saved before or after download,
and selecting a preset switches spoken output to Downloaded voices. Conversation
languages remain a separate setting: choosing Kumo doesn't change an
English/Chinese conversation to Japanese. Set Japanese as one side of the pair
to hear Japanese translations in that voice. Speech recognition and text
translation models still need their own downloads in **Offline Languages**;
the voice pack supplies spoken output only.

Downloads show progress, support cancellation and retry, and verify every file's
size and SHA-256 before making the shared pack available. A partial download
can't be used for playback. **Delete shared voice pack** removes all downloaded
voices after unloading the model and keeps your selections. Local verification
runs again at startup; the first preview or spoken line can also need time to
prepare CoreML. The library shows preview preparation status, and playback waits
for the local check instead of starting a download. Missing or invalid files
produce download guidance.

The model comes from
[Kokoro-82M-CoreML-INT8 at revision 4ef656f](https://huggingface.co/aufklarer/Kokoro-82M-CoreML-INT8/tree/4ef656f55554ceb242ed11febbdbbffd60dd5938),
based on [hexgrad/Kokoro-82M](https://huggingface.co/hexgrad/Kokoro-82M).
The local runtime adapts
[speech-swift at revision 31d676c](https://github.com/soniqo/speech-swift/tree/31d676c6a7f1a3f9e3004c06914de54e61f0f987).
The model and runtime are Apache-2.0; pronunciation resources include MIT
attributions. The bundled manifest pins every downloaded file. See the
[runtime documentation](Packages/NeuralVoices/README.md) and
[notices](Packages/NeuralVoices/NOTICE) for the source, modifications, and licenses.

Apple shares and manages speech recognition and text translation assets, and may
remove unused models. Reopen Offline Languages before travel, then verify a fresh
launch in airplane mode with both languages. Releasing a speech language frees
an app reservation; it does
not immediately delete shared system files. Manage translation downloads in
Apple's Translate settings. Android's existing ML Kit typed/photo fallback is
unchanged; this offline recognition and translation setup is for iOS/macOS.

Device checks on 2026-11-13 used an iPhone 17 Pro running iOS 27.0.1. Fixed
English and Chinese recordings passed through the real microphone file-input
path, Speech framework, and installed translation models. Both spoken and typed
directions produced final translations with the expected meaning. The app's
network policy was held offline, URLSession requests were blocked, and no app
network attempts occurred during those cases. No live microphone audio was
recorded or retained.

The device exposed a cold-start inconsistency: one language-availability check
reported not installed, and the first translation raised `notInstalled`, before
succeeding on the bounded local retry. The app still reports actual system
readiness and never converts a failed check into a saved ready flag. Missing
models still fail with download guidance.

The original Soniox Chinese voice was replayed and confirmed by listening.
Actual network radios stayed connected during automated checks, so a fresh
airplane-mode launch and a live two-person offline conversation remain
unverified. These fixture checks establish the on-device pipeline; they don't
measure recognition accuracy across real speakers, accents, or noisy rooms.

The camera button at the start of the text field translates a photo, such as
a sign or a menu. Take one (iPhone and iPad) or choose one from Photos. Its
text is read on the device with Vision (`Support/TextRecognizer.swift`; ML Kit
text recognition on Android), one
line per line of text, and added as a typed turn, so it's translated the same
way and can be corrected with Edit.

Swipe a turn in the transcript to delete it, or long-press it (right-click on Mac)
for Edit and Delete. Edit fixes a misheard transcript, such as a name, and
translates the corrected text again the same way as typed lines. In face-to-face,
long-press one of your own lines to edit it.

On iPhone and iPad, Lively has home screen and lock screen widgets
(`LivelyWidgets/`). They show the conversation's two languages, and tapping one
opens Lively and starts listening. The medium home screen widget also has a
Type button that opens the text field. They link with `lively://listen` and
`lively://type`, and read the language pair from the `group.sh.ian.lively` App
Group, which the app updates whenever the pair changes
(`Shared/WidgetLanguages.swift`). The Android app has no widgets yet.

Settings › Pickup range keeps distant conversations out of the transcript.
Audio quieter than the range's threshold is sent to the engine as silence, and
the ring around the mic button fades while that happens. **Nearby** (the
default) hears people around the table, **Close** only those right by the
phone, and **Whole room** everything. **Auto** tracks the room's background
level and only hears speech well above it, never laxer than Nearby. The
thresholds live in `Audio/NoiseGate.swift`.

**Speech-to-speech** (off by default) reads translations aloud. Original Soniox
uses Text-to-Speech (`tts-rt-v2`), following
[Soniox's speech-to-speech guide](https://soniox.com/docs/translation/sts-translation).
On iOS and macOS, Downloaded voices use the verified local Kokoro pack described
above. Android continues to use Soniox.
Turn it on and off from the ••• menu in face-to-face or in Settings ›
Speech-to-Speech. While it's on, the transcript's top bar shows a speaker
button that turns it off. Sentences are queued when their translations become
final; Soniox uses its own stream over one WebSocket and downloaded voices
generate audio locally. While it speaks, the mic sends silence so
Lively doesn't translate its own voice, unless audio goes to headphones; tapping
or holding the mic cuts it off. The voice choice is independent of the
recognition/translation engine. Original Soniox needs a Soniox key (the broker's
`/v1/soniox/tts-key`, or a key in Settings); downloaded voices need the local pack.

On **iOS 26.2 or later**, choose **Your language** in Settings › Speech-to-Speech.
Incoming translations into that language play only through connected headphones;
outgoing translations into the other language play through the built-in speaker.
The headset must support both input and output (for example, AirPods or wired
headphones with a microphone). Without a compatible headset, incoming translations
remain visible but are not spoken. Playback waits before switching destinations,
keeping each sentence on its selected output. This uses
Apple's `multiRoute` / `dualRoute` audio session and maps output channels to the
appropriate device. On earlier iOS versions, macOS, and Android,
speech-to-speech continues to speak only translations into the second language
through the normal audio output.

Soniox only outputs Simplified Chinese. When Settings › Chinese is 繁體, Lively
converts its output on the device.

## Run

The Android app lives in [`android/`](android/README.md). Everything below
describes the iOS and macOS app; the Android app mirrors it file by file.

Open `Lively.xcodeproj` and run the **Lively** scheme on an iPhone, iPad
simulator, or **My Mac**.

Soniox works without any setup. Builds get temporary keys from the deployed
broker at `https://lively.ian.sh` (see
[Server/key-broker](Server/key-broker/README.md)). For Voxtral, add a Mistral
key in Settings.

Lively Pro is an App Store subscription that raises the daily translation
allowance (`Model/Pro.swift`, `Views/ProView.swift`). The key broker checks
each signed transaction itself; see
[Server/key-broker](Server/key-broker/README.md#lively-pro). To try purchases
from Xcode, pick `Config/Lively.storekit` under Edit Scheme › Run › Options ›
StoreKit Configuration. The broker doesn't accept those local test
transactions, so this exercises only the UI. Use a TestFlight build with a
Sandbox account for the full flow.

To try the UI without a key, add the launch argument `-LivelyDemo YES` and tap the
mic. It plays a scripted conversation through the real turn and translation logic.
For unattended screenshots, also pass `-LivelyDemoAutoPlay YES` to start the demo
when the conversation screen appears.

## How it works

| Stage | Where |
|---|---|
| Mic → 16 kHz PCM16, 80 ms chunks | `Audio/MicCapture.swift` |
| Pickup range: quiet chunks sent as silence | `Audio/NoiseGate.swift` |
| Engine registry: names, keys, which settings apply, how to build each pipeline | `Model/SpeechProvider.swift` |
| Engine interface and events | `Networking/SpeechEngine.swift` |
| On-device ASR for the stopgap and fallback (Speech framework) | `Networking/OfflineSpeechEngine.swift` |
| Local stopgap, audio buffer, replay and handoff to the server | `Networking/HybridSpeechEngine.swift` |
| Reconnects, pings, audio backlog, shared by every engine | `Networking/ResilientSocket.swift` |
| Voxtral: WebSocket to `voxtral-mini-transcribe-realtime-3`, language auto-detected, turn detection on | `Networking/RealtimeTranscriber.swift` |
| Voxtral: streaming translation over Mistral chat completions | `Networking/Translator.swift` |
| Typed lines: DeepSeek through the broker, falling back to on-device translation | `Networking/Translator.swift` |
| Photos: text read on the device with Vision, then translated as a typed line | `Support/TextRecognizer.swift` |
| Soniox: WebSocket to `stt-rt-v5` with two-way translation and endpoint detection | `Networking/SonioxTranscriber.swift` |
| Soniox: temporary keys from the broker, with one spare kept ready | `Networking/SonioxKeyProvider.swift` |
| Soniox: picks the region (US or Japan) with the shortest round trip | `Networking/RegionProber.swift` |
| Key broker: Cloudflare Worker that mints temporary Soniox keys and translates text | `Server/key-broker/` |
| Turns, utterances, translation scheduling, which sentences to speak | `Model/ConversationStore.swift` |
| Speech-to-speech: Soniox `tts-rt-v2`, a stream per sentence | `Networking/SonioxSpeaker.swift` |
| Offline voice catalog, verified shared download, and per-language selections | `Model/NeuralVoiceCatalog.swift`, `Model/NeuralVoicePacks.swift` |
| Downloaded speech queue, previews, and shared model lifetime | `Networking/NeuralSpeaker.swift` |
| Local CoreML synthesis and language frontends | `Packages/NeuralVoices/` |
| Speech-to-speech: 24 kHz playback, mutes the mic while audible | `Audio/SpeechPlayer.swift` |

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
   single-use key that expires in 60 s, with its region's WebSocket URL.
3. `SonioxTranscriber.makeRequest()` takes a key for each connection and
   opens the WebSocket to that URL directly. Audio never goes through the broker.
4. While listening, the provider keeps one spare key and replaces it about
   every 50 s, so a reconnect on a flaky network doesn't wait on the broker.
   Taking the spare starts fetching the next one.
5. Soniox rejects an expired or reused temporary key with `error_code` 401 in
   its first message. The transcriber then reconnects with a fresh key. After 3
   rejections in a row it gives up and says so, instead of blaming a key in
   Settings.

### Soniox regions

Soniox runs separate US and Japan regions. From East and Southeast Asia, Japan
saves about 150–250 ms per translation ([measurements](Tools/probe/ASIA_LATENCY.md)).
Each region is its own Soniox project, and a temporary key works only in the
region that minted it.

- `RegionProber` measures every region the broker lists. A probe is three
  `GET https://stt-rt.<region>.soniox.com/` on one connection; the RTT is the
  faster of the last two, so handshakes don't count.
- It probes at launch, on foreground, when the network path changes, every
  10 min while listening, and after 2 failed connects. It never probes on a
  timer while idle.
- Each region's score is a smoothed RTT plus up to 500 ms for failed probes and
  connects. The choice moves only to a region at least 25% and 40 ms better.
- The choice goes to the broker as `Lively-Region` and applies to the next
  connection only. A live socket is never moved. A spare key from the old
  region is dropped.
- After 2 failed connects in a row in one region, the next connection goes to
  the next-best region.
- Before the first probe the app sends no region, and the broker picks one
  from the caller's country.

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

- Audio keeps recording while the socket is down, with up to 60 s held in a
  backlog that is replayed on reconnect.
- Soniox reports how much audio it has finalized, so audio sent but not yet
  finalized when a session drops goes back in the backlog and is sent again:
  words in flight at the moment of a dropout aren't lost.
- Once onboarding is done, a session opens as the app launches and is held
  with keepalives, so the first tap on the mic is live at once. It closes
  after 60 s if nobody starts listening.
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

## Audio regression tests

On a Mac with Xcode installed, run:

```sh
python3 Tools/tests/run_regressions.py --thread-sanitizer
```

The suites compile production source with controlled audio, network, and
permission dependencies. They cover startup cancellation, speech direction,
channel ordering, disconnect/reconnect bursts, settings changes, session
ownership, and error cleanup. Negative controls deliberately break routing and
settings behavior in temporary source copies and check that the tests detect it.
The microphone lifecycle suite also exercises real AVFoundation conversion with
a generated audio file; Thread Sanitizer checks its concurrent lifecycle work.
The offline suites cover selected-language recognition, local text translation,
original-voice suppression offline, downloaded-voice selection without cloud
credentials, network loss, both translation download directions, system asset
removal, quota and download failures, cancellation, and stale callbacks. Speech
and translation services are controlled in these regressions; they don't prove
real model accuracy or replace an airplane-mode conversation on a phone.

The neural voice suites exercise the production catalog and download manager
with controlled file downloads: all presets, independent saved selections,
pinned manifests, manifest bounds, hash failures, atomic installation, retry,
late callbacks, shared cold-start verification, and invalidation before awaited model unloading
and deletion. Speaker tests cover queues, selected voices and outputs, preview
completion and cancellation, invalid audio, shared model loading/unloading, and
installation changes during preparation. Negative controls deliberately remove
these protections and must be detected. Preview lifecycle tests execute the
production Settings and library callbacks with delayed dependencies, including
rapid taps, stale progress and errors, background cleanup, and cancellation of
conversation speech before previews. The NeuralVoices package tests cover
Japanese Unicode handling, chunking, request validation, malformed assets,
cancellation, unloaded streams, and bundled license notices. The aggregate
command above includes all four suites, with Thread Sanitizer when requested.
These tests use controlled rendering or frontend-only cases; they don't establish
real iPhone CoreML synthesis, cold-start latency, pronunciation, or voice quality.

Neural voice device checks on 2026-11-13 used the iPhone 17 Pro running iOS 27.0.1.
The production download manager fetched and verified all 75 files
(92,022,138 bytes). Using this model with CoreML's `.all` compute route crashed
with `SIGABRT` inside Apple's MPSGraph compiler on repeated axes. The CPU-only
route generated audio successfully; production now defaults to `.cpuOnly` on
iOS and keeps `.all` on macOS.

With CPU-only inference, the cold Japanese Alpha preview reached its first
audio/Playing state in 5.15 s including model loading. Its 4.1 s sample contained
finite audio (RMS 0.077, peak 0.344). Warm English Heart reached audio in 0.40 s
and produced a 3.375 s finite sample (peak 0.376). Warm Japanese Alpha and Kumo
reached audio in 0.42 s and 0.44 s, respectively. These measure preview
preparation and generation, not a full translation conversation. The active
route was the iPhone speaker (`Speaker:2`), without an active AirPods route.
The user initially reported hearing neither preview. A separate standard
playback check reported speaker volume at 5%. After raising it to 55%, the
listener confirmed that Japanese Alpha and English Heart sounded good. That
check used pre-rendered clips with AVAudioPlayer; it confirms the samples are
audible, rather than the full on-phone synthesis and directional playback path.
These neural-voice checks did not include airplane mode.

These tests do not replace an iPhone check with AirPods: verify both languages,
unplug/reconnect during playback, and confirm that incoming speech stays in the
headset while outgoing speech uses the phone speaker. The simulator has no
Bluetooth audio hardware to validate that routing.

Device checks on 2026-11-13 used an iPhone 17 Pro running iOS 27.0.1 with
AirPods and a separately signed development copy of this branch. The real
Soniox demo played English translations in AirPods and Chinese translations
from the phone, confirmed by listening. The active dual-route session exposed
two headset channels and two speaker channels; both channel maps were accepted.

Ten real microphone start/stop cycles produced audio chunks and released every
session claim. Disconnecting and reconnecting AirPods stopped private playback
without moving it to the speaker, then restored headphone playback. A local
audio probe also ran two players simultaneously for four rounds; listening
confirmed separate headphone and speaker output, and both claims released.
Normal conversation playback still queues translated sentences in order.

Normal conversation startup and a Home Screen round trip were also verified.
Backgrounding stopped capture and released all session claims; one tap after
returning restarted the real microphone. No crash occurred during these checks.
Phone-call interruption and a long-session soak have not yet been verified.
These audio checks did not cover widget sharing in the separate development app.
