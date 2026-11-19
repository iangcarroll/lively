# Lively paid marketing plan (iOS)

Written 2026-11-19. Lively is live on the App Store as
`Lively: Live Translator` (app `6835590432`). Android is out of scope here,
except where a prerequisite is a product change that must ship on both apps.

## Summary

Run Apple Search Ads only, as a small staged test. Don't scale it until two
things are fixed: nothing can be measured today, and most users never reach
the Lively Pro screen. At current pricing and the current free allowance, paid
installs in the US probably won't pay back.

## Economics

Figures marked *assumed* are placeholders; replace them with real numbers as
soon as the test produces them.

- **Revenue per subscriber.** $39.99/year nets about $34 after Apple's 15%
  Small Business rate (about $28 at 30%). $4.99/month nets about $4.24.
  Blended first-year net per subscriber: about **$28** (*assumed*: Small
  Business rate, and a mix of yearly and short-lived monthly subscribers).
- **Cost to acquire.** US Apple Search Ads taps for Travel and Utilities run
  about $1–2 at the median, depending on the source. The cross-category
  average cost per install was $3.76 in 2025. No reliable install cost for
  travel apps specifically was found.
- **Conversion.** Freemium apps convert about 2% of installs to paid within 35
  days (2.6% on iOS). Hard-paywall apps convert about 10%.
- **Cost of free use.** Soniox lists $0.12–0.18 per real-time hour; its pages
  disagree on whether translation costs extra. A free user costs cents per
  trip, which is small next to the install cost. A Pro subscriber who used all
  10 hours every day would cost more than the subscription earns, so watch
  heavy use as Pro grows.

Break-even cost per install at $28 net per subscriber:

| Install-to-Pro rate | Break-even cost per install |
|---|---|
| 1% | $0.28 |
| 2.6% (iOS freemium median) | $0.73 |
| 5% | $1.40 |
| 10% | $2.80 |

Lively needs roughly 8–10% install-to-Pro to break even on US installs. It is
set up to convert below the freemium median: one free hour a day (two when
signed in) covers most trips, and neither plan has a trial or intro offer.

## Prerequisites

Do these before spending more than the test budget.

1. **Measurement.** The app has no attribution code. Add Apple's AdServices
   attribution token, send it to the key broker, and join it to subscription
   events so Pro conversions can be read per keyword. It needs no tracking
   prompt and no third-party SDK, so the listing's "No ads or cross-app
   tracking" line holds. Recheck the privacy labels in
   [metadata.md](metadata.md) and `Lively/PrivacyInfo.xcprivacy` when adding it.
2. **Paywall reach.** Pick at least one:
   - a free trial on the yearly plan;
   - a short non-renewing "trip pass";
   - a smaller free allowance for new anonymous installs.

   Each is a product change and ships on iOS and Android together.
3. **Localised listing.** The App Store metadata is English only. Add Japanese
   and Traditional Chinese before buying those storefronts.

## The test

- **Budget:** about $1,500–2,000 over four weeks.
- **Storefronts:** US, plus one or two cheaper storefronts with heavy travel
  (Japan, Taiwan, Hong Kong) once the listing is localised.
- **Match type:** exact match in every campaign except Discovery.

| Campaign | Keywords | Purpose |
|---|---|---|
| Brand | lively translator | Cheap defence |
| Category | live translator, voice translator, interpreter | Volume; most expensive |
| Language pair | english to japanese translator, chinese translator | Likely best intent |
| Competitor | other translator apps | Test only |
| Discovery | Search Match, broad match | Find terms, then move winners to exact |

Add every exact-match keyword as a negative in Discovery so the campaigns
don't bid against each other.

**Custom product pages.** Point each ad group at a matching page: Japan trip,
Chinese, offline, face-to-face. The screenshot sets in `marketing/` already
cover these themes.

**Read weekly, by keyword:**

- tap-to-install rate
- cost per install
- install to first conversation
- install to Lively Pro screen
- install to Pro

**Rules:**

- Scale keywords where cost per subscriber is under about $28.
- Pause a keyword at about $40 spent with no installs, or about 150 installs
  with no subscriber.
- If no keyword group clears break-even after four weeks, stop and fix paywall
  reach before spending again.

**Timing.** Start now so the winning keywords are known before year-end
travel, Chinese New Year (February 2027) and Japan's spring season.

## Later channels

- **Paid creators.** Travel YouTubers covering Japan and China trips are the
  second channel. Measure them with App Store offer codes and custom product
  page links, which need no tracking.
- **Meta, TikTok, Google.** Skip for now. They need an SDK or coarse SDK-less
  attribution (AdAttributionKit), and an SDK would contradict the listing's
  privacy claim and change the privacy labels.

## Positioning

Apple's free Translate app is the bar: about 30 languages and accents in
iOS 27, plus AirPods Live Translation on recent AirPods. Lead with what Lively
does differently:

- one phone between two people, each side facing its reader;
- automatic detection of the other person's language;
- no AirPods needed;
- a bilingual transcript that stays.

Check Apple's current language list before making any language claim in an ad.

## Open questions

- Is Cautela enrolled in the App Store Small Business Program (15% vs 30%)?
- What are current organic installs and install-to-Pro? They replace the
  assumed figures above.
- What is the monthly ceiling once a keyword group clears break-even?

## Sources

- Soniox: [pricing](https://soniox.com/pricing),
  [translation pricing comparison](https://soniox.com/compare/translate/pricing)
- Apple Search Ads benchmarks:
  [AppTweak 2026](https://apptweak.com/en/aso-blog/apple-ads-benchmarks),
  [SplitMetrics](https://splitmetrics.com/blog/apple-search-ads-cost),
  [RocketShip HQ](https://www.rocketshiphq.com/?p=5321)
- Conversion:
  [AppFollow on RevenueCat's 2026 medians](https://appfollow.io/blog/subscription-metrics-mobile-app),
  [Adapty State of In-App Subscriptions 2026](https://adapty.io/state-of-in-app-subscriptions-2026)
- Attribution:
  [RevenueCat on AdServices](https://www.revenuecat.com/blog/iad-vs-adservices-whats-the-difference/),
  [Singular Apple Ads attribution](https://support.singular.net/hc/en-us/articles/115003234483-Apple-Search-Ads-Attribution-Integration)
- Apple Translate:
  [9to5Mac on iOS 27 languages](https://9to5mac.com/2026/07/08/ios-27-adds-nine-new-languages-and-accents-to-apple-translate/),
  [App Store listing](https://apps.apple.com/app/id1514844618)
