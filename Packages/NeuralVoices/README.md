# NeuralVoices

Local-only CoreML Kokoro runtime for iOS 26 and macOS 26. The app owns model
downloads, integrity checks, the voice catalog, and playback. This package has
no remote dependencies, network client, system speech voice, or fallback engine.

```swift
import NeuralVoices

let engine = NeuralVoiceEngine()
try await engine.load(directory: verifiedModelDirectory)
let samples = try await engine.synthesize(
    text: "こんにちは。駅はどこですか。", voiceID: "jf_alpha", language: "ja")
// samples: mono Float32 at NeuralVoiceEngine.sampleRate (24,000 Hz).
await engine.unload()
```

For chunked delivery, iterate `engine.stream(text:voiceID:language:)`. Cancel the
consumer task when speech stops. Cancellation is checked around each CoreML
prediction and between chunks; a prediction already running cannot be aborted.
Chunks are never dropped. Requests are limited to 4,096 characters to bound
buffered output. Loading releases the old model before constructing another.

The engine actor owns every model reference and serializes loading and
synthesis away from the main actor. `load` accepts an explicit CoreML compute
route; it never changes routes automatically. Unsupported languages, missing or
corrupt files, unavailable voices, and unloaded state produce typed errors.

`NeuralVoiceEngine.defaultComputeUnits` is `.cpuOnly` on iOS and `.all` on
macOS; `load(directory:computeUnits:)` still accepts an explicit override.
On the tested iPhone 17 Pro with iOS 27.0.1, `.all` aborted in MPSGraph
compilation with a repeated permutation axis; `.cpuOnly` completed Japanese
and English previews. Other iPhone models and OS versions have not been validated.

Language identifiers use ISO/BCP-47 codes. The runtime maps English (`a`/`b`),
Japanese (`j`), Mandarin (`z`), Spanish (`e`), French (`f`), Hindi (`h`), Italian
(`i`), and Portuguese (`p`) voice prefixes. Actual
availability depends on the verified files supplied by the app. This list does
not claim every language has a voice in the standard bundle or equal quality.

The standard local bundle layout includes `kokoro_5s.mlmodelc`,
`vocab_index.json`, and `voices/*.json`. English pronunciation assets include
`us_gold.json`, `us_silver.json`, `G2PEncoder.mlmodelc`, `G2PDecoder.mlmodelc`,
and `g2p_vocab.json`.
Keep the full verified manifest when supporting every voice in a bundle.

Run `swift test` for pure frontend, chunking, asset-error, unloaded-stream, and
cancellation checks. These tests do not allocate a model or establish voice
quality, pronunciation accuracy, or iPhone performance. Model-backed device
acceptance is a separate app check.

Adapted Apache-2.0 source and modification details are recorded in `NOTICE`;
the complete license is in `LICENSE`. Additional pronunciation notices are in
`ThirdPartyNotices`; bundled text is available through `NeuralVoiceEngine.licenseNotices`.
Model weights are not included.
