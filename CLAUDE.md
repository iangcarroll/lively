# Lively

Live conversation translation with three clients that must stay equivalent:

- **iOS / macOS**: SwiftUI in `Lively/`, project `Lively.xcodeproj`.
- **Android**: Kotlin + Compose in `android/`, ported file by file from the
  Swift app (see the table in `android/README.md`).
- **Key broker**: Cloudflare Worker in `Server/key-broker/`, shared by both apps.

## Feature parity (required)

Every user-facing change ships on **both** iOS/macOS and Android in the same
change. This covers features, UI and layout, settings, copy, engine and
translation behaviour, and bug fixes that aren't specific to one platform.

- Don't call a task done, commit, or push until both apps have it, unless the
  user explicitly says to do only one platform for this change.
- Mirror the structure: put the Kotlin counterpart in the file that matches
  the Swift one (`Views/FaceToFaceScreen.swift` ↔ `ui/FaceToFace.kt`,
  `Model/ConversationStore.swift` ↔ `model/ConversationStore.kt`, and so on),
  with the same names and the same comments where they apply.
- Where a platform API differs, use the closest native equivalent and say so
  in a comment (for example, Apple's Translation framework on iOS and ML Kit
  on Android for on-device translation).
- Build both apps before finishing: the Xcode `Lively` scheme for an iOS
  simulator and for macOS, plus `cd android && ./gradlew :app:assembleDebug
  :app:testDebugUnitTest`. Try the change in demo mode on each when it's
  visible (`-LivelyDemo YES` on iOS, `--ez LivelyDemo true` on Android).
- If something truly can't be done on one platform, tell the user what is
  missing and why, rather than shipping one side silently.
- Update both READMEs when behaviour they describe changes.

## Workflow

Commit and push straight to `main`; no feature branches or PRs.
