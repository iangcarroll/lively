# Lively for Android

A native Android version of Lively, in Kotlin and Jetpack Compose with
Material 3. It does everything the iOS app does, with the same engines, key
broker, account and Pro allowance:

- Face-to-face layout on phones (the far half upside down), a chat transcript
  from the ⋮ menu, and side-by-side columns at 600 dp and wider (unfolded
  foldables, tablets, landscape, Chromebooks).
- Soniox through the key broker by default, or Voxtral + Mistral with your own
  key. Keys entered in Settings are encrypted with an Android Keystore key.
- Region probing, a spare key, reconnects with backlog replay (including
  audio Soniox hadn't finalized when the session dropped), catch-up
  sessions after a dropout, make-before-break handover when the network
  changes, a warm session for a quick resume, and one opened at launch so
  the first tap on the mic is live at once. All of it is a port of the
  Swift code, file by file (see the table below).
- Tap the mic to start and stop, or hold it to listen only while it's
  pressed, as on iOS.
- Speech-to-speech, off by default: the ⋮ menu in face-to-face (or Settings) reads
  translations into the second language aloud with Soniox Text-to-Speech,
  muting the mic while it speaks unless headphones are connected.
- Typing instead of speaking from the keyboard button, translated by
  DeepSeek through the key broker, falling back to ML Kit on the device
  (Apple's Translation framework on iOS).
- Translating a photo from the camera button in the text field: take one
  or choose one, and ML Kit reads its text on the device (Vision on iOS)
  and adds it as a typed turn. The Latin, Chinese, Japanese, Korean and
  Devanagari models are bundled, so it works offline and without Play
  services.
- The live on-device stopgap and fallback are iOS/macOS only: Apple's Speech
  and Translation frameworks have no Android equivalent for streaming
  on-device ASR plus translation. Android keeps the ML Kit fallback for typed
  text and uses Soniox or Voxtral for speech. This is the app's one intentional
  platform difference; see [../README.md](../README.md#engines).
- Swipe a turn in the transcript, or long-press it, to delete it. Long-press
  also offers Edit, which fixes a misheard transcript and translates it
  again; in face-to-face, long-press one of your own lines.
- Optional email sign-in, and Lively Pro through Google Play Billing. The
  broker checks Play purchases with the Play Developer API
  ([Server/key-broker](../Server/key-broker/README.md#google-play-subscriptions)).
- The welcome tour, 60 languages with each reader's prompts in their own
  language, Simplified → Traditional Chinese on the device, dark mode, edge to
  edge, predictive back, themed icon, TalkBack labels, right-to-left halves for
  Arabic, Hebrew, Persian and Urdu readers, and Space to start and stop on a
  hardware keyboard.

Android 10 (API 29) and later. Lively stops listening when it goes to the
background, as on iOS.

## Build and run

Open `android/` in Android Studio, or:

```bash
cd android && ./gradlew :app:installDebug
```

The key broker URL is `https://lively.ian.sh`; override it with
`-PlivelyKeyBrokerUrl=…` (empty means Soniox needs a key in Settings).

### Launch options

The iOS launch arguments are intent extras here:

```bash
adb shell am start -n sh.ian.lively/.MainActivity --ez LivelyDemo true --ez LivelyDemoAutoPlay true
```

| Extra | Does |
|---|---|
| `LivelyDemo` | Plays a scripted conversation through the real pipeline, without a key. Sign-in accepts any email and the code 123456. Pro shows sample prices. |
| `LivelyDemoAutoPlay` | Starts the demo when the conversation appears. |
| `LivelyOnboarding` | Shows the welcome tour on every launch. |
| `LivelyAudioFile PATH` | Debug builds: plays a 16-bit WAV into the app instead of the mic. |
| `LivelyDropout "AT,FOR"` | Debug builds: blackholes the network FOR seconds, AT seconds in. |
| `LivelySlowConnect SECONDS` | Debug builds: holds up each connection attempt, so a second one races it. |
| `LivelyPathChange AT` | Debug builds: reports a network change AT seconds in. |

To try real audio on an emulator, render the test conversation and hand it
to the app:

```bash
python3 Tools/probe/make_conversation.py /tmp/conv
adb push /tmp/conv/conversation.wav /data/local/tmp/conv.wav
adb shell run-as sh.ian.lively sh -c 'mkdir -p files && cp /data/local/tmp/conv.wav files/'
adb shell am start -n sh.ian.lively/.MainActivity -e LivelyAudioFile /data/user/0/sh.ian.lively/files/conv.wav
```

## Tests

```bash
./gradlew :app:testDebugUnitTest          # JVM: turns, translation, Soniox tokens, broker client
./gradlew :app:connectedDebugAndroidTest  # on a device or emulator: onboarding, demo, settings, sign-in
```

GitHub Actions runs the unit tests, lint and a minified release build on
every change under `android/`.

## Release

`./gradlew :app:bundleRelease` makes the Play bundle. Put the upload key in
`~/.gradle/gradle.properties` as `livelyKeystore`, `livelyKeystorePassword`,
`livelyKeyAlias` and `livelyKeyPassword`; without them, release builds are
signed with the debug key so they can be tried locally. The version code is a
UTC timestamp (`yyMMddHH`), or `-PlivelyBuildNumber=…`.

Before Pro works on Android:

1. In Play Console, create the subscriptions `sh.ian.lively.pro.monthly` and
   `sh.ian.lively.pro.yearly`, each with one auto-renewing base plan.
2. Give the key broker a service account, as its README describes.

The launcher icon layers come from `Tools/icon/make_android_icon.swift`, which
draws the same bubbles as the iOS icon.

## How it maps to the iOS app

| iOS | Android |
|---|---|
| `Audio/MicCapture.swift` | `audio/MicCapture.kt` (AudioRecord, `VOICE_RECOGNITION`, 80 ms chunks) |
| `Audio/NoiseGate.swift` | `audio/NoiseGate.kt` (same thresholds) |
| `Networking/ResilientSocket.swift` | `net/ResilientSocket.kt` (OkHttp WebSockets) |
| `Networking/SonioxTranscriber.swift`, `SonioxKeyProvider.swift`, `RegionProber.swift` | `net/` files of the same names |
| `Networking/RealtimeTranscriber.swift`, `Translator.swift` | `net/RealtimeTranscriber.kt`, `net/MistralTranslator.kt`, `net/BrokerTranslator.kt`, `net/OnDeviceTranslator.kt` |
| `Model/ConversationStore.swift` | `model/ConversationStore.kt` |
| `Networking/SonioxSpeaker.swift` | `net/SonioxSpeaker.kt` (OkHttp WebSocket) |
| `Audio/SpeechPlayer.swift` (AVAudioEngine) | `audio/SpeechPlayer.kt` (AudioTrack; no shared audio session to coordinate) |
| `Model/Account.swift`, `Pro.swift` | `model/Account.kt`, `model/Pro.kt` (Play Billing) |
| `Support/Keychain.swift` | `support/Stores.kt` (Keystore-sealed preferences, kept out of backups) |
| `NLLanguageRecognizer` | `model/LanguageDetector.kt` (script counting, then `TextClassifier`) |
| Vision text recognition (`Support/TextRecognizer.swift`) | `support/TextRecognizer.kt` (ML Kit, a model per script) |
| `StringTransform("Hans-Hant")` | ICU `Transliterator("Hans-Hant")` |
| `Views/*` | `ui/*` |
