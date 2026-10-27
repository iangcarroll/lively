# Lively App Store metadata

## Product page

- Name: `Lively Translate`
- Subtitle: `Live English–Chinese speech`
- Promotional text: `Talk naturally across English and Chinese. Lively recognizes both languages, translates each turn live, and gives each person a view they can read.`
- Keywords: `translator,translation,Chinese,English,conversation,speech,voice,travel,interpreter,Mandarin`
- Support URL: `https://lively.ian.sh/support`
- Marketing URL: none (the repository is private)
- Primary category: Travel
- Secondary category: Utilities
- Copyright: `2026 Certly, Inc.`

## Description

Lively helps English and Chinese speakers understand each other in real time.

Put your iPhone between two people and start talking. Lively automatically detects which language is being spoken, finds natural turn boundaries, and translates each turn as it happens. There is no need to choose a speaker or press a button for every sentence.

Designed for face-to-face conversations:

- Live English ⇄ Chinese transcription and translation
- Face-to-face phone layout, with each language oriented toward its reader
- Side-by-side bilingual view on iPad and wider screens
- Simplified or Traditional Chinese output
- Resilient listening that recovers from brief network interruptions
- No account required with the default translation engine
- Lively Pro: up to 10 hours of translation a day
- No advertising or cross-app tracking

Lively is free to try, with an hour of translation a day, or two when you sign in. Lively Pro is an auto-renewing subscription with up to 10 hours a day. Payment is charged to your Apple Account, and the subscription renews unless cancelled at least 24 hours before the end of the period. Manage it in your Apple Account's Subscriptions.

Microphone audio is processed by the selected speech provider to provide live transcription and translation. See Lively's privacy policy for details.

Terms of Use: https://lively.ian.sh/terms
Privacy Policy: https://lively.ian.sh/privacy

## Review information

- Sign-in required: No
- Notes: `Lively does not require an account. To exercise the primary flow, skip the optional email sign-in, allow microphone access, tap the microphone, and speak English or Chinese. The default Soniox engine obtains a temporary key automatically. Free use is an hour a day (two hours when signed in with a one-time email code). Lively Pro, an auto-renewing subscription in Settings › Lively Pro, raises it to 10 hours a day; Restore Purchases is on the same screen. Accounts can be deleted in Settings › Account › Delete Account. Settings also offers an optional Voxtral + Mistral engine for users who provide their own Mistral API key.`
- Release: Manual release after approval

## In-app purchases

One subscription group, **Lively Pro**, with two auto-renewable subscriptions.
The product IDs must match `Pro.productIDs` in the app and `PRO_PRODUCT_IDS` in
`Server/key-broker/wrangler.jsonc`.

| Product ID | Reference name | Period | Level |
|---|---|---|---|
| `sh.ian.lively.pro.yearly` | Lively Pro Yearly | 1 year | 1 |
| `sh.ian.lively.pro.monthly` | Lively Pro Monthly | 1 month | 2 |

- Display name: `Lively Pro`. Description: `10 hours of live translation a day`.
- Prices are set in App Store Connect. `Config/Lively.storekit` uses $4.99 and $39.99 for local testing only.
- Each product needs a review screenshot of the paywall (Settings › Lively Pro).
- Submit both with the first version that includes Pro.
- License agreement: Apple's standard EULA, linked from the description and from `https://lively.ian.sh/terms`.
- App Store Server Notifications V2: `https://lively.ian.sh/v1/appstore/notifications`, for Production and Sandbox.

## Content and privacy declarations

- Content rights: Lively does not contain, show, or access third-party content.
- Age rating: None for all mature-content categories; no unrestricted web access, user-generated-content feed, remote messaging, advertising, gambling, or health content.
- Privacy policy: `https://lively.ian.sh/privacy`
- Account deletion URL: `https://lively.ian.sh/delete-account`
- Data types:
  - Email Address — app functionality; linked to the optional account; not used for tracking.
  - Device ID — app functionality; not linked to identity; not used for tracking.
  - Audio Data — app functionality; not linked to identity; not used for tracking.
  - Other User Content — app functionality; not linked to identity; not used for tracking.
  - Purchase History — app functionality; not linked to identity; not used for tracking.
- Keep these in step with `Lively/PrivacyInfo.xcprivacy`.

## Screenshots

- iPhone with Dynamic Island (medium display), 1206 × 2622:
  - `screenshots/iphone-medium/01-face-to-face.jpg`
  - `screenshots/iphone-medium/02-transcript.jpg`
- iPad 13-inch, 2064 × 2752:
  - `screenshots/ipad-13/01-parallel-transcript.jpg`
