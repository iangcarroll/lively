# Lively paid marketing plan (iOS)

**November 21, 2026 (Pacific).** All five US Apple Ads Search Results campaigns are **running**. All eight ad groups are enabled. The **US$1,000 total cap** includes the initial language-pair test. The five campaigns share a stop time of **December 6 at 8:00 a.m. Pacific**. [Apple Ads dashboard](https://app-ads.apple.com/cm/app/25739240/report)

## Launch and spend

- We first launched the Japanese and Chinese ad groups with six English exact-match keywords under a **US$250 cap**. Brand, Category, Competitor and Discovery were paused at that point.
- Later on November 21 we activated those four campaigns and extended Language pair to the same end date. **None of the five campaigns is paused.** Apple reported **US$0.00** at the launch check. Reporting can lag by up to three hours. [Campaign dashboard](https://app-ads.apple.com/cm/app/25739240/report)
- Apple schedules these campaigns in Hong Kong time. Its settings export shows November 20 as the original start date and **December 7 at 00:00 HKT** as the saved end time on all five. Counting both dates and the days spent paused gives a conservative upper bound of **18 × US$55 = US$990** across the entire test. Actual spend depends on taps. [How Apple applies dated campaign budgets](https://ads.apple.com/app-store/help/bids-and-budget/0016-manage-budgets)

## What is done

| Area | Verified status |
| --- | --- |
| Targeting | The five campaigns have 17 exact keywords and three broad keywords. Discovery excludes all 17 exact keywords at campaign level. [Campaign settings and keyword list](https://github.com/iangcarroll/lively/tree/main/AppStore/apple-ads) |
| Attribution | The broker and database migration are deployed, production App Store notifications point to the broker, and the private report resolves all 20 bid keywords by name. The updated privacy policy and App Store privacy label are published. [Attribution PR](https://github.com/iangcarroll/lively/pull/19) · [Privacy policy](https://lively.cautela.hk/privacy) |
| iOS release | The US App Store carries **0.1.2 (202611200104)** with AdServices attribution. It requires iOS 26.0 or later. [Release PR](https://github.com/iangcarroll/lively/pull/20) · [US App Store](https://apps.apple.com/us/app/lively-live-translator/id6835590432) |
| US product pages | Apple approved all four custom pages and the **Live transcript vs. offline voices** product page optimization test. The four custom ads are enabled in the groups shown below. [Product pages in App Store Connect](https://appstoreconnect.apple.com/apps/6835590432/distribution/productpages) |
| Localization | The public iOS interface, onboarding and 0.1.2 store listing are in English. Japanese and Traditional Chinese listing copy and screenshots are prepared for a later storefront launch. [Storefront PR](https://github.com/iangcarroll/lively/pull/18) · [Localized assets](https://github.com/iangcarroll/lively/tree/main/AppStore/localizations) |

## US campaign setup

| Running campaign | Average US$/day | Ad groups | Max US$/tap | Product pages by group |
| --- | ---: | --- | ---: | --- |
| Brand | 4 | Brand | 0.50 | Default |
| Category | 12 | Conversation / Offline | 1.00 / 0.85 | Face-to-face conversations / Offline travel translation |
| Language pair | 24 | Japanese / Chinese | 1.10 each | Japanese for your trip / English and Chinese conversations |
| Competitor | 4 | Other translators | 0.65 | Default |
| Discovery | 11 | Broad / Search Match | 0.70 each | Default |

Brand, Category, Language pair and Competitor use exact match. Discovery tests three broad terms (*travel translator*, *two way translator*, *speech translation*) and enables automatic Search Match only in its dedicated group. Promote promising search terms to exact match and add corresponding exact negatives to Discovery. [Target keywords](https://github.com/iangcarroll/lively/blob/main/AppStore/apple-ads/us-search.json)

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
- Let the campaigns end on December 6 Pacific. Scale only keywords whose mature cost per paid subscriber is below roughly **$28** and whose observed proceeds and service costs support it. Agree a new budget before extending the campaign dates.
- If no group clears break-even, address paywall reach before another flight. The free allowance is one hour a day anonymously and two when signed in. Neither subscription currently has an introductory offer. The open product decision is a yearly trial, a short trip pass or a smaller allowance for new anonymous users. Coordinate the chosen change across iOS and Android.

## Storefronts, positioning and later channels

All five campaigns use the **US storefront**, with English ad copy and English bid keywords. There is no device-language restriction, and Discovery can match additional search terms. Japan, Taiwan and Hong Kong are expansion candidates. Use the US results and the readiness of localized onboarding and listings to decide whether to test another storefront.

For travel creative, lead with two people sharing one phone, automatic language detection, face-to-face reading and a bilingual transcript. Neither person needs AirPods. Check current Apple Translate capabilities before making a comparative language claim. Year-end travel, Lunar New Year and Japan's spring travel season are opportunities for creative once the campaigns are ready.

Travel creators covering trips to Japan and Chinese-speaking destinations are the next channel to test, using offer codes and custom page links. Meta, TikTok and Google remain deferred until the search test establishes viable acquisition economics.
