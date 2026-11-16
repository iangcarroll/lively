# Lively

Live conversation translation for iOS, macOS and Android.

Either person speaks whenever they want. The speech engine detects the language
and turn boundaries, and the transcript keeps each turn with its translation.

## Conversation modes (iOS / macOS)

**Automatic** is the default with the Soniox engine. Choose only **Your language**
in Settings: the language you read and hear. There is no conversation pair to
set and no speaker-selection popup. The other side stays **Automatic** until
speech identifies a supported partner language; an unknown destination never
falls back to the saved manual pair.

The Soniox connection uses persistent `one_way` translation into Your language.
Incoming translations stay on that stream. Once a partner language is known,
your completed turns are translated into it through the broker's text translator.
Discovering or changing the partner language does not reconnect the stream.
The first confirmed final source can establish the partner immediately. Changing
an established partner requires two distinct agreeing final-source segments.
Each completed turn keeps its own languages and target, so a later partner
change affects future turns without relabeling the history.

Your words appear even before the partner language is known. On discovery, the
most recent three completed waiting turns receive visible translations without
automatic playback. Older waiting turns keep a neutral **Translate** action.
After ten minutes without conversation activity, runtime partner context resets
for the next encounter; visible history remains in its original direction.

**Choose a pair** retains Soniox's native `two_way` translation. Both directions
arrive on the speech stream, avoiding Automatic's extra outgoing text request.
Use this mode for the lower-latency paired path, or for explicit offline setup.
Voxtral and the On-device engine continue to use a selected pair.

Automatic language discovery requires Soniox and internet. It does not switch to
a fixed-language local recognizer when the connection drops. Prepare a manual
pair and select the On-device engine for offline conversations; unrestricted
offline automatic detection is not supported. Android retains its existing
paired runtime and has not received this mode.

## Engines

Pick one in Settings › Engine. Soniox gets temporary keys from Lively's key
broker, so it needs no setup. Voxtral needs your own Mistral key. Keys entered in
Settings are stored in the Keychain.

| Engine | How it works | Key |
|---|---|---|
| **Soniox** (default) | `stt-rt-v5`: Automatic uses `one_way` incoming translation plus text translation for outgoing turns; Choose a pair uses native `two_way` translation | from the [key broker](#soniox-keys), or your own from console.soniox.com |
| **Voxtral + Mistral** | `voxtral-mini-transcribe-realtime-3` transcribes and detects turns, then a Mistral chat model translates each turn | console.mistral.ai |
| **On-device** (iOS/macOS) | Apple's Speech and Translation frameworks run on this device. No key, and no audio leaves the device | none |

Soniox won the earlier [selected-pair benchmark](Tools/probe/RESULTS.md), which
used the native paired path. That result does not measure the new Automatic
mode's outgoing text-translation latency; Automatic has not been benchmarked
against that path.

In paired mode, Soniox and Voxtral identify which selected language is spoken.
Automatic uses Soniox without fixed-pair language hints. While a cloud session
connects or retries,
audio waits in a bounded buffer; the app does not substitute a fixed-language
recognizer. A warm Soniox session is reused when listening resumes. Stopping
listening lets accepted audio finish processing, including audio captured before
the connection was ready. After connection loss, Soniox can also replay sent audio
that the service has not finalized. Voxtral retains unsent queued audio; it does
not report finalized audio positions, so already-sent speech cannot be recovered
with the same guarantee.

Retained replay stays bounded to sixty seconds of audio. Providers without a
separate catch-up stream send that retained speech in order before live audio.
Soniox catch-up retries retain both unsent audio and the suffix the service has
not finalized, including when a retry falls during an outage. Recovery keeps the
original thirty-second catch-up deadline. Ending the session discards pending
recovery; a brief microphone pause still lets accepted audio finish processing.

In the iOS/macOS paired cloud path, **HybridSpeechEngine** switches to the
selected on-device input language only when the network becomes unavailable,
then returns to automatic
cloud recognition when connectivity returns. Prepare speech and translation in
**Settings › Offline Languages** before going offline. Online service errors stay
visible instead of silently changing to fixed-language recognition. Android keeps
its existing cloud speech and ML Kit typed-text behavior (see
[android/README.md](android/README.md)).
Changing the offline input language while online applies to the next fallback
without interrupting the active cloud conversation.

Tap the mic to start and stop listening, or hold it to listen only while it's
pressed, like a walkie-talkie: letting go ends the turn and stops the mic.

In iOS and macOS, the listening reminder appears for five seconds when listening
starts, then fades. On iPhone it briefly returns when you turn or move the phone
substantially to hand it to another reader. Both face-to-face halves share the
reminder; the transcript shows it above the mic. It uses both known languages,
or an Automatic state while the partner is unknown. The mic keeps its **Stop**
label while active and **Start** while off. Stopped, connecting, and offline
guidance stays visible; VoiceOver also keeps the listening instructions visible.
Headers, reminders, typing fields, and controls reserve their own space above or
below the transcript. While following the conversation, the newest turn stays
in view as guidance, text size, or keyboard size changes. Layout changes keep
your place when you scroll back to read earlier turns.

When speaking isn't practical, the keyboard button opens a text field. Typed
lines go to DeepSeek through the key broker, falling back to on-device
translation (Apple's Translation framework; ML Kit on Android). Voxtral uses its
own Mistral translator for them. Automatic applies the same bound-target rules
to typed lines: your text waits visibly when the partner language is unknown.
If a short typed line cannot identify its language, the app uses the language of
the reader beside the text field. Editing a known foreign source-only turn
explicitly translates the corrected words into Your language.

## Addresses (iOS / macOS)

Open **More › Address** from either conversation layout. Paste an address or place
name, choose **Address language**, and tap **Find address**. Confirm the matching
place using its name, address, and map, then copy the written address or open that
location in Maps.

Address lookup has its own language preference. Opening it pauses conversation
audio; it does not speak the result or change the conversation's languages,
speech engine, or voice settings. Lookup uses Apple Maps and requires internet,
including when offline speech packs are installed. Address details and spelling
depend on available map data, and some proper names keep their local spelling.
Queries and address results are kept only for the current lookup screen.

## Offline conversations (iOS / macOS)

Choose a language pair in Settings, then open **Offline Languages** and
**Download languages** while online.
The screen checks the full speech models for both conversation languages and
translation models in both directions. Unsupported languages are marked for the
current device. Change the pair in Settings to prepare another pair; Apple's
speech storage limit may require releasing an unused language first.

Choose **Use on-device translation** to keep recognition and translation local,
even while connected. Choose **Input language** in **Settings › Offline Languages** for the person
speaking offline. Local recognition uses that language explicitly; paired online
recognition identifies the selected languages. The conversation screen has no
speaker-selection prompt.
Typed text, edits, and text read from photos also use local translation in this
mode or when the network is unavailable and a translation target is known,
without waiting for a cloud request.
Missing models produce download guidance instead of starting a download while
listening. In paired cloud mode, downloaded local models take over when the
network path becomes unavailable; the cloud provider reconnects after it returns.
If an online session loses its path without downloaded speech models, it keeps a
bounded audio buffer and waits for the connection instead of ending listening.

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
languages remain a separate setting: choosing Kumo does not choose a translation
destination. Automatic learns Japanese from the partner's speech; paired and
offline conversations require choosing Japanese in the pair. Speech recognition
and text translation models still need their own downloads in **Offline Languages**;
the voice pack supplies spoken output only.

Downloads show progress, support cancellation and retry, and verify every file's
size and SHA-256 before making the shared pack available. A partial download
can't be used for playback. **Remove download** removes all downloaded
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
Those earlier fixture checks kept the network radios connected. The later
English/Japanese airplane-mode acceptance run below verifies a fresh offline
launch with downloaded voices. A live two-person offline conversation and
recognition accuracy across speakers, accents, or noisy rooms remain unverified.

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
(`LivelyWidgets/`). Automatic shows Your language and **Automatic**; paired mode
shows the saved pair. Tapping one
opens Lively and starts listening. The medium home screen widget also has a
Type button that opens the text field. They link with `lively://listen` and
`lively://type`, and read the saved language mode from the
`group.sh.ian.lively` App Group. The app updates the widget when saved language
settings change
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

On **iOS 26.2 or later**, Automatic uses **Settings › Languages › Your language**;
paired mode keeps **Your language** under Speech-to-Speech.
Incoming translations into that language play only through connected headphones;
outgoing translations into the detected or selected other language play through
the built-in speaker.
The headset must support both input and output (for example, AirPods or wired
headphones with a microphone). Without a compatible headset, incoming translations
remain visible but are not spoken. Playback waits before switching destinations,
keeping each sentence on its selected output. This uses
Apple's `multiRoute` / `dualRoute` audio session and maps output channels to the
appropriate device. On earlier iOS versions, macOS, and Android,
speech-to-speech uses the normal audio output: outgoing translations in Automatic,
or translations into the pair's second language in paired mode.

Soniox only outputs Simplified Chinese. When Settings › Chinese is 繁體, Lively
converts its output on the device.

## Run

The Android app lives in [`android/`](android/README.md). Everything below
describes the iOS and macOS app. Android shares much of the earlier paired
architecture, but its runtime is unchanged by the new Automatic mode.

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

In a Debug build, to try the UI without a key, add the launch argument `-LivelyDemo YES` and tap the
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
| On-device ASR for explicit offline input (Speech framework) | `Networking/OfflineSpeechEngine.swift` |
| Network fallback, offline audio buffer, replay and cloud handoff | `Networking/HybridSpeechEngine.swift` |
| Reconnects, pings, audio backlog, shared by every engine | `Networking/ResilientSocket.swift` |
| Voxtral: WebSocket to `voxtral-mini-transcribe-realtime-3`, language auto-detected, turn detection on | `Networking/RealtimeTranscriber.swift` |
| Voxtral: streaming translation over Mistral chat completions | `Networking/Translator.swift` |
| Typed lines: DeepSeek through the broker, falling back to on-device translation | `Networking/Translator.swift` |
| Photos: text read on the device with Vision, then translated as a typed line | `Support/TextRecognizer.swift` |
| Soniox Automatic: persistent one-way incoming stream, source lanes and optional targets | `Networking/AutomaticSonioxTranscriber.swift` |
| Soniox paired: WebSocket to `stt-rt-v5` with native two-way translation and endpoint detection | `Networking/SonioxTranscriber.swift` |
| Soniox: temporary keys from the broker, with one spare kept ready | `Networking/SonioxKeyProvider.swift` |
| Soniox: picks the region (US or Japan) with the shortest round trip | `Networking/RegionProber.swift` |
| Key broker: Cloudflare Worker that mints temporary Soniox keys and translates text | `Server/key-broker/` |
| Turns, utterances, translation scheduling, which sentences to speak | `Model/ConversationStore.swift` |
| Speech-to-speech: Soniox `tts-rt-v2`, a stream per sentence | `Networking/SonioxSpeaker.swift` |
| Offline voice catalog, verified shared download, and per-language selections | `Model/NeuralVoiceCatalog.swift`, `Model/NeuralVoicePacks.swift` |
| Downloaded speech queue, previews, and shared model lifetime | `Networking/NeuralSpeaker.swift` |
| Local CoreML synthesis and language frontends | `Packages/NeuralVoices/` |
| Speech-to-speech: 24 kHz playback, mutes the mic while audible | `Audio/SpeechPlayer.swift` |

Engines report events in the following ways:

- **Transcribe only** (Voxtral). Text deltas and turn boundaries come from the
  engine, and `ConversationStore` translates each turn with a
  `TranslationService`.
- **Transcribe and translate** (paired Soniox). The engine reports whole segments with
  their translation. The adapter closes the segment at Soniox's `<end>` endpoint
  token. Non-final tokens are previews, replaced by the next response.
- **Automatic Soniox**. Incoming native translations target the saved listener
  language; outgoing source turns get a text-translation request only after a
  partner target is bound. Foreign originals with no aligned native translation
  can remain source-only. Confirmed incoming translations can also appear on a
  separate row with an unavailable original, without inventing source words.

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
3. The paired or Automatic Soniox adapter takes a key for each connection and
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

- Paired Soniox translates in the same stream as transcription, with endpoint detection
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
- **iPad, Mac, landscape, unfolded Duo** (≥ 640 pt wide): side-by-side columns.
  Automatic keeps Your language and Other language as stable reader roles;
  each historical row retains its actual language labels.

Your language uses indigo and partner languages use vermilion in Automatic.
Paired mode colors the first and second languages respectively, in both light
and dark mode.

## Audio regression tests

On a Mac with Xcode installed, run:

```sh
python3 Tools/tests/run_regressions.py --thread-sanitizer
```

Rendering checks are an optional Simulator run, separate from the aggregate:

```sh
python3 Tools/tests/ui_state_regression.py --device-id BOOTED_SIMULATOR_UDID --negative-controls
```

The runner copies the actual views and model into a separate test host, with
explicit Store, settings, and control boundaries. It checks failure, network,
known-partner, unknown-partner, source-only, and unidentified-language states,
plus assertion-based fault controls. It adds no QA mode to Lively and uses no
microphone or service credentials. Generated app identities are unique to the
run and removed during cleanup; logs and screenshots remain in the printed
results directory.

The suites compile production source with controlled audio, network, and
permission dependencies. They cover startup cancellation, speech direction,
channel ordering, disconnect/reconnect bursts, settings changes, session
ownership, and error cleanup. Negative controls deliberately break routing and
settings behavior in temporary source copies and check that the tests detect it.
The microphone lifecycle suite also exercises real AVFoundation conversion with
a generated audio file; Thread Sanitizer checks its concurrent lifecycle work.
The online suites cover source-language revisions, native translation metadata,
short replayed turns, stalled requests, transcript side and spoken direction,
warm startup, paused final words, and obsolete engine callbacks. Parser-to-store
integration checks preserve rapid replies, mixed-language names, and confirmed
translation direction. If source ownership is ambiguous, the original words stay
visible and the confirmed translation appears separately with its source
transcript marked unavailable. A native URLSession WebSocket test uses a loopback
server to inspect actual audio and
finalization order, rapid Stop/resume, and cancelled connection setup.

Automatic adds dedicated suites for saved-mode/listener settings
(`automatic_settings_regression.py`), the production one-way adapter and a saved
service capture (`automatic_soniox_regression.py`), and real Store/Utterance
methods (`automatic_conversation_regression.py`). They cover unknown targets,
silent recent-turn backfill, stable historical directions, source-only captions,
runtime context expiry and stale callbacks, with separate fault controls. They
are included in the aggregate runner. Physical microphone and AirPods acceptance
are tracked separately from the deterministic suites.

Temporary XCUITests outside the shipped app exercised the normal Automatic
onboarding, active language search in both directions, manual pair search, side
swapping, unknown-partner prompts, a typed waiting turn, and portrait/parallel
layouts, including a dark-mode replay. The run found an iOS search-controller
crash when a searchable language list was popped while search was active.
Pinning iOS language search to the navigation-bar drawer fixed the reproduced
case. The separate address-language sheet passed the same active-search
selection flow without that change. These simulator checks do not establish
live speech accuracy, Automatic's end-to-end latency, or Bluetooth routing. A
fresh physical iPhone/AirPods acceptance run for Automatic is still pending;
the earlier paired/offline checks below are separate evidence.

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
A later fresh-process airplane-mode run passed all five required pipeline cases
and all nine automatic checks in 39 seconds: typed English/Japanese, prerecorded
spoken English/Japanese, and a same-store Japanese microphone stop/restart. It
used the selected Kumo Japanese and Alloy English voices. Every generated byte
was scheduled and every frame completed; the maps isolated Japanese output to
the phone speaker and English output to AirPods. The observed network path was
unavailable from process startup through cleanup, with no forced offline policy,
no intercepted app HTTP attempts after the tripwire self-test, and no retained
audio-session claims. The user separately confirmed the instructed airplane-mode
run completed and sounded good.

The [sanitized acceptance report](Tools/validation/offline-airplane-2026-11-13.json)
keeps the automatic and user confirmations separate. Inputs were fixed recordings
through the app's Debug audio-file path, rather than a live microphone
conversation. These results cover two selected voices and fixed phrases; they
don't establish accuracy across speakers or noisy rooms. The public network API
doesn't observe the airplane-mode switch, and the HTTP tripwire doesn't observe
all framework-service traffic.

Regression tests and acceptance reports stay under Tools and the package's test
target. Release builds exclude the screenshot demo, canned sign-in responses,
recording injection, and simulated connection faults. Temporary device-QA
screens, fixture assets, report collectors, and networking tripwires are not part
of the shipped app.

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
