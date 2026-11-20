# Lively paid marketing plan (iOS)

**November 19, 2026.** Start with a four-week US Apple Ads search results test. The five campaigns are **paused**, with **$0 spent**. Their daily budgets total **$55**, or **$1,540 over 28 days** within the original $1,500–$2,000 test range. Choose the flight dates once a public iOS build can attribute a paid subscription to its keyword. The four weeks run from activation. [Apple Ads dashboard](https://app-ads.apple.com/cm/app/25739240/report)

## What is done

| Area | Verified status |
| --- | --- |
| Campaigns | Five US campaigns and eight ad groups exist in Apple Ads. All 17 exact keywords and three broad keywords have bids. Discovery excludes all 17 exact terms at campaign level. [Campaign settings and keyword list](https://github.com/iangcarroll/lively/tree/main/AppStore/apple-ads) |
| Attribution | PR #19 merged. The broker and database migration are deployed, production App Store notifications point to the broker, and the private report resolves all 20 bid keywords by name. The updated privacy policy is live. [Attribution PR](https://github.com/iangcarroll/lively/pull/19) · [Broker deployment](https://github.com/iangcarroll/lively/actions/runs/44623741417) · [Privacy policy](https://lively.cautela.hk/privacy) |
| iOS release | Attribution build `202611192156` is in external TestFlight. App Store Connect marks 0.1.1 build `202611191855` Ready for Distribution. That earlier build predates attribution. Both require iOS 26.0. [TestFlight build workflow](https://github.com/iangcarroll/lively/actions/runs/44623741405) |
| US product pages | Apple shows all four custom pages and the **Live transcript vs. offline voices** product page optimization test as **Waiting for Review**, together in one submission. The language-pair pages lead with real English/Japanese and English/Traditional Chinese conversations. [Product pages in App Store Connect](https://appstoreconnect.apple.com/apps/6835590432/distribution/productpages) |
| Localized listings | PR #18 merged Japanese and Traditional Chinese listing copy and screenshots for all four supported device placements. The 0.1.1 store listing has only US English. The localized assets are ready for the next editable version. [Storefront PR](https://github.com/iangcarroll/lively/pull/18) · [Localized assets](https://github.com/iangcarroll/lively/tree/main/AppStore/localizations) |

## US campaign setup

| Campaign | Average daily budget | Ad groups | Max cost per tap |
| --- | ---: | --- | ---: |
| Brand | $4 | Brand | $0.50 |
| Category | $12 | Conversation / Offline | $1.00 / $0.85 |
| Language pair | $24 | Japanese / Chinese | $1.10 each |
| Competitor | $4 | Other translators | $0.65 |
| Discovery | $11 | Broad / Search Match | $0.70 each |

Brand, Category, Language pair and Competitor use exact match. Discovery tests three broad terms (*travel translator*, *two way translator*, *speech translation*) and enables automatic Search Match only in its dedicated group. Promote promising search terms to exact match and add corresponding exact negatives to Discovery. [Target keywords](https://github.com/iangcarroll/lively/blob/main/AppStore/apple-ads/us-search.json)

## Before the first paid install

1. Publish the updated App Privacy answers and release an iOS build containing attribution. The production broker is ready to receive it. [App Privacy declarations](https://github.com/iangcarroll/lively/blob/main/AppStore/metadata.md#content-and-privacy-declarations)
2. Confirm the billing profile and add a valid payment method. Apple Ads currently shows a payment hold.
3. When Apple approves the pages, assign **Face-to-face conversations** to Conversation, **Offline travel translation** to Offline, **Japanese for your trip** to Japanese and **English and Chinese conversations** to Chinese. Use the default listing for Brand, Other translators and Discovery.
4. Set start and end dates on the existing campaigns, then enable the campaigns and ad groups for the flight. Watch cumulative spend against $1,540 because the daily budgets are averages.

## How to read the test

| Weekly question | Metric and source |
| --- | --- |
| Which terms bring new users? | In Apple Ads, divide tap-through **new downloads** by taps for the download rate, and spend by those new downloads for acquisition cost. Use the search terms report to find candidates for exact match. |
| Which keywords bring paying customers? | In the broker report, filter to tap-through new-download cohorts. Count the first positive-price production charge on each original Pro subscription once. Trials count when they convert. Renewals and restores add no second conversion. Broad match identifies the bid keyword. Apple can omit the keyword for Search Match, so report those installs at ad-group level. [Reporting query and definitions](https://github.com/iangcarroll/lively/blob/main/Server/key-broker/README.md#apple-ads-keyword-conversions) |
| Is the spend paying back? | Compare each keyword's spend with first-paid subscriptions from the corresponding acquisition period. Divide paid subscriptions by attributed installs for install-to-Pro. Broker cohorts start when the app delivers attribution. Label the cohort age and allow 35 days to assess conversion. The first-charge count is gross of later refunds and cancellations. |
| Where do users drop off? | First-conversation and Pro-screen views still lack keyword-level measurement. The launch-day organic download-to-paid cohorts had insufficient data. Record missing metrics as unavailable and fill in the organic baseline when Apple reports mature cohorts. [App Store Connect Analytics](https://appstoreconnect.apple.com/apps/6835590432/analytics/overview) |

## Economics and decisions

US Pro pricing is $39.99/year and $4.99/month. At a 15% commission those yield about $34 and $4.24 respectively per payment. At 30% the annual plan yields about $28. The **$28 blended first-year proceeds per paid subscriber** used below are a planning assumption. Confirm Small Business Program enrollment, renewal mix, refunds and translation costs before raising the budget. [US store listing](https://apps.apple.com/us/app/lively-live-translator/id6835590432) · [Soniox usage pricing](https://soniox.com/pricing)

| Install-to-Pro rate | Maximum cost per install at $28 per subscriber, before service costs |
| ---: | ---: |
| 1% | $0.28 |
| 2.6% | $0.73 |
| 5% | $1.40 |
| 10% | $2.80 |

- Pause a keyword at roughly **$40 spent with zero new installs**. At roughly **150 new installs with zero paid subscriptions**, pause once the conversion window has elapsed.
- End the planned spend at four weeks. Scale only keywords whose mature cost per paid subscriber is below roughly **$28** and whose observed proceeds and service costs support it. Agree a monthly ceiling and choose how to improve paywall reach before increasing spend.
- If no group clears break-even, address paywall reach before another flight. The free allowance is one hour a day anonymously and two when signed in. Neither subscription currently has an introductory offer. The open product decision is a yearly trial, a short trip pass or a smaller allowance for new anonymous users. Coordinate the chosen change across iOS and Android.

## Storefronts, positioning and later channels

The US language-pair campaigns target travelers searching in the **US storefront**. Japan, Taiwan and Hong Kong are expansion candidates. Publish the corresponding localized listings, then use the US results to decide whether to test one or two of those storefronts within an agreed budget.

For travel creative, lead with two people sharing one phone, automatic language detection, face-to-face reading and a bilingual transcript. Neither person needs AirPods. Check current Apple Translate capabilities before making a comparative language claim. Year-end travel, Lunar New Year and Japan's spring travel season are opportunities for creative once the campaigns are ready.

Travel creators covering trips to Japan and Chinese-speaking destinations are the next channel to test, using offer codes and custom page links. Meta, TikTok and Google remain deferred until the search test establishes viable acquisition economics.
