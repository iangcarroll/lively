# Lively App Store metadata

Apple team: `JYM7F5DWS2`. App bundle ID: `hk.cautela.lively`.
App Store Connect app: `6835590432` (Lively: Live Translator). The Apple
subscription products below use the Cautela namespace. Android keeps its
existing Play product IDs in the separate `PLAY_PRODUCT_IDS` allowlist.

## Product page

- Name: `Lively: Live Translator`
- Subtitle: `Speak, type & translate live`
- Promotional text: `Understand each other with live translation, a shared face-to-face view, and bilingual transcripts. Type, translate photos, or prepare languages for offline use.`
- Keywords: `voice,conversation,interpreter,travel,Chinese,English,Japanese,Spanish,photo,offline,speech`
- Support URL: `https://lively.cautela.hk/support`
- Marketing URL: `https://lively.cautela.hk`
- Primary category: Travel
- Secondary category: Utilities
- Copyright: `2026 Cautela Limited`

## Description

Every word. Both languages.

A quick question at the station. A conversation over dinner. A new place that suddenly feels a little more familiar. Lively helps you understand each other with live voice translation, a shared conversation view, and clear bilingual transcripts.

TALK NATURALLY
Choose your two languages, tap the microphone, and start talking. With the default online engine, Lively recognizes either language and translates as the conversation unfolds. No need to select a speaker or tap for every sentence.

ONE PHONE. BOTH SIDES.
Place your iPhone between two people. Face-to-face mode turns each language toward its reader. Switch to the transcript to follow both languages together, or enjoy a spacious side-by-side view on iPad.

MORE WAYS TO SAY IT
Type when speaking is inconvenient. Translate text from a photo of a menu or sign. Correct a misheard word and translate it again. Choose Simplified or Traditional Chinese output.

HEAR THE TRANSLATION
Turn on spoken translations to hear the words aloud. Choose online speech or download the offline voice library: 54 voices across eight languages. On supported iPhones, compatible headphones can keep incoming translations in your ears while the other person hears the device speaker.

PREPARE FOR OFFLINE MOMENTS
Download supported speech and translation models before you travel, then choose on-device translation. Offline spoken output requires the separate voice download. Availability depends on the language and device; online voices still require internet.

YOUR LANGUAGES, YOUR CONVERSATION
Choose from the app's supported language pairs, including English, Chinese, Japanese, Spanish, French, German, and more. Online and offline language availability can differ.

START WITHOUT AN ACCOUNT
The default online engine works without a personal API key or account. Get up to one hour of translation a day free, or two hours when you sign in. Lively Pro raises the daily allowance to up to 10 hours. No ads or cross-app tracking.

Lively Pro is an optional auto-renewing subscription. Payment is charged to your Apple Account. It renews unless cancelled at least 24 hours before the end of the current period. Manage or cancel in your Apple Account's Subscriptions.

Online translation sends audio or text to the selected providers. On-device mode processes supported speech and text locally; the spoken-voice setting is separate. See the privacy policy for details.

Terms of Use: https://lively.cautela.hk/terms
Privacy Policy: https://lively.cautela.hk/privacy

## Review information

- Sign-in required: No
- Notes: `Lively does not require an account. To exercise the online flow, choose Allow Online Processing, skip optional sign-in, and allow microphone access. Tap the microphone and speak in your language and a supported second language. On-device processing is available as a separate choice. The default Soniox engine obtains a temporary key automatically. Free use is an hour a day (two hours when signed in, with Sign in with Apple or a one-time email code). Lively Pro, an auto-renewing subscription in Settings › Lively Pro, raises it to 10 hours a day; Restore Purchases is on the same screen. Accounts can be deleted in Settings › Account › Delete Account. Settings also offers an optional Voxtral + Mistral engine for users who provide their own Mistral API key.`
- Release: Manual release after approval

## In-app purchases

One subscription group, **Lively Pro**, with two auto-renewable subscriptions.
The product IDs must match `Pro.productIDs` in the app and `APP_STORE_PRODUCT_IDS` in
`Server/key-broker/wrangler.jsonc`.

| Product ID | Reference name | Period | Level |
|---|---|---|---|
| `hk.cautela.lively.pro.yearly` | Lively Pro Yearly (Cautela) | 1 year | 1 |
| `hk.cautela.lively.pro.monthly` | Lively Pro Monthly (Cautela) | 1 month | 1 |

- Display name: `Lively Pro`. Description: `10 hours of live translation a day`.
- US prices: $4.99/month and $39.99/year, with Apple's regional equivalents.
  `Config/Lively.storekit` uses the same US prices for local testing.
- Each product needs a review screenshot of the paywall (Settings › Lively Pro).
- Submit both with the first version that includes Pro.
- License agreement: Apple's standard EULA, linked from the description and from `https://lively.cautela.hk/terms`.
- Sign in with Apple account changes: `https://lively.cautela.hk/v1/auth/apple/notifications`.
- App Store Server Notifications V2: `https://lively.cautela.hk/v1/appstore/notifications`, for Production and Sandbox.

## Content and privacy declarations

- Content rights: Lively displays Apple Maps place results and offers third-party voice assets. Cautela Limited confirmed the necessary rights for the selected territories.
- Age rating: None for all mature-content categories; no unrestricted web access, user-generated-content feed, remote messaging, advertising, gambling, or health content.
- Privacy policy: `https://lively.cautela.hk/privacy`
- Account deletion URL: `https://lively.cautela.hk/delete-account`
- Data types (all declared linked; none used for tracking):
  - Email Address — app functionality; optional account authentication.
  - User ID — app functionality; optional account and provider credentials.
  - Product Interaction — app functionality; translation usage counters.
  - Device ID — app functionality; installation/network identifiers and abuse prevention.
  - Audio Data — app functionality and other purposes; provider processing and possible model training.
  - Other User Content — app functionality and other purposes; translation text and possible model training.
  - Purchase History — app functionality; persistent subscription transaction identifiers.
- Location is not declared: the optional "Set from location" setting passes an
  approximate location to Apple's reverse geocoder on the device's behalf and
  keeps only the country code on the device. Nothing is sent to Lively or its
  providers. On Google Play, review the Data safety form for the new
  `ACCESS_COARSE_LOCATION` permission before the next release.
- These answers cover every supported engine. The optional Mistral engine uses
  the user's own API key, so requests can be associated with that provider
  account. Mistral's retention and training controls depend on the user's plan
  and settings. The default Soniox real-time engine processes conversation
  content transiently; Lively's broker does not retain conversation content.
- Sources: [Apple's disclosure definitions](https://developer.apple.com/app-store/app-privacy-details/),
  [Mistral privacy policy](https://legal.mistral.ai/terms/privacy-policy/), and
  [Mistral training controls](https://help.mistral.ai/en/articles/347617-do-you-use-my-user-data-to-train-your-artificial-intelligence-models).
- Keep these in step with `Lively/PrivacyInfo.xcprivacy`.

## Screenshots and creative artwork

These are marketing compositions with real app captures, feature headlines,
custom artwork, and device frames. Raw captures are retained separately.

- iPhone medium: `marketing/iphone-medium/`, four PNGs at 1206 × 2622.
- iPhone large: `marketing/iphone-large/`, four PNGs at 1320 × 2868.
- iPad 13-inch: `marketing/ipad-13/`, one PNG at 2064 × 2752.
- Header: `creative/product-page-header.png`, 3840 × 1646.
- Search results: `creative/search-results.png`, 1920 × 1280.
- Preview: `marketing/contact-sheet.png`.
- Rebuild with `swift Tools/store-assets/render.swift` from the repository root.
  Obtain the official Apple frames as described in `creative/device-frames/README.md`.
- Main screenshot: “Every word. Both languages.”; four panels total.
- Subscription review screenshots: `review/lively-pro-paywall.jpg` (yearly) and
  `review/lively-pro-monthly.jpg` (monthly), each captured with its plan selected.
- Artwork provenance and prompt: `creative/PROMPT.md`.

The private reviewer address and code are stored in
App Store Connect review notes. The address and code hash are Worker secrets, never committed here. Sign-in
remains optional; this account uses the normal free plan so reviewers can
exercise subscription purchase and restore. Review contact is entered directly
in App Store Connect.

Public TestFlight link: https://testflight.apple.com/join/9U2kcPRH
