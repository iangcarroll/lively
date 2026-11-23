# Lively iOS acquisition plan

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

## First delivery check

**November 22, 2026, around 4:30 p.m. Pacific**, roughly 22 hours after launch. All five campaigns showed Running. The figures below cover the launch through the check, including the partial November 23 UTC reporting day. Apple Ads reporting can lag by three hours. [Campaign dashboard](https://app-ads.apple.com/cm/app/25739240/report)

| US campaign | Impressions | Taps | Spend | Tap-through installs |
| --- | ---: | ---: | ---: | ---: |
| Discovery | 1 | 0 | $0.00 | 0 |
| Brand, Category, Language pair and Competitor combined | 0 | 0 | $0.00 | 0 |
| **Total** | **1** | **0** | **$0.00** | **0** |

Discovery’s **Broad** group received the impression on the bid keyword **speech translation**. The production attribution report had **0 attributed installs and 0 first-paid Pro subscriptions** across launch cohorts. With no taps, cost per install and tap-to-install conversion are undefined. There is too little delivery to judge a keyword, product page or paywall. [Discovery report](https://app-ads.apple.com/cm/app/25739240/report/campaign/2145166598) · [Pro attribution definitions](https://github.com/iangcarroll/lively/blob/main/Server/key-broker/README.md#apple-ads-keyword-conversions)

At the 48-hour check, if the exact-match groups still have no impressions, check keyword eligibility, search popularity and Apple’s suggested bids for the leading Category and Language pair terms. A popular, eligible term with a bid below Apple’s range is a candidate for a single-keyword bid test within the existing cap. Low search volume calls for testing different wording. [Apple Ads recommendations](https://ads.apple.com/app-store/help/recommendations/0055-review-recommendations)

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

## Organic acquisition tests

Start with English-speaking US iPhone owners preparing for a trip. **Run two tests first:** one placement that reaches travelers after they book, and one guide travelers can find through search. Both can reuse the same Kyoto station demo and point to the approved **Japanese for your trip** page. The Taipei ticket demo and **English and Chinese conversations** page give us a second destination to test. All seven ideas below are proposed, unpaid placements.

| Channel | First test | What to count |
| --- | --- | --- |
| **1. Seats.aero travel content** | Propose a short “after you book Japan” tip for a relevant Seats.aero guide or editorial slot. Show two people confirming a train platform on one iPhone. Use one placement with its own App Store link. [Seats.aero guides](https://seats.aero/guides/gettingstarted) | Outbound clicks from that placement and first-time downloads from its link. |
| **2. Google organic search** | Publish an English guide on Lively’s site answering “How do I ask which train platform to use in Japan?” Include the phrase, a real transcript and steps a reader can use at the station. Offer the Japanese page after the answer. If the guide attracts travelers, repeat for buying a ticket in Taipei. [Google Search guidance](https://developers.google.com/search/docs/fundamentals/creating-helpful-content) | Search Console clicks from relevant queries, guide-to-store clicks, and first-time downloads from the guide link. Allow four weeks for the first search read. |
| **3. Study-abroad orientations** | Offer three US-facing Japan or Taiwan program advisers a one-slide arrival exercise. A student and partner role-play asking for a ticket, then scan the matching product-page QR code. CIEE’s Taipei program is one prospect. [CIEE Taipei](https://www.ciee.org/go-abroad/college-study-abroad/locations/taiwan/taipei) | Advisers who use the slide, orientation dates, QR visits and downloads by program. |
| **4. Independent tour operators** | Offer a Japan specialist a short offline-setup checklist for a single US departure. Ask whether its pre-departure pack can include the checklist and a link to **Offline travel translation**. InsideJapan’s US self-guided trips are an example. [InsideJapan self-guided trips](https://www.insidejapantours.com/us/self-guided-japan-holidays/) | Departures that include the checklist, clicks from each operator’s link and first-time downloads. |
| **5. Lively’s own YouTube channel** | Turn the Kyoto demo into a captioned 20-second Short and a one-minute walkthrough. Show the question, the other person’s reply and the split-screen transcript. Use the Short’s related-video link to reach the walkthrough and put the store link in the walkthrough description. [YouTube related videos](https://support.google.com/youtube/answer/14075157?hl=en) · [YouTube link placement](https://support.google.com/youtube/answer/13748639?hl=en) | Walkthrough views, store-link visits and first-time downloads. Use completion rate to refine the clip. |
| **6. US language schools** | Offer a free paired exercise to instructors who teach Japanese for travel. Students try asking for directions on their own and use the transcript to check what was understood. Japan Society’s traveler workshop illustrates the audience. [Japan Society traveler workshop](https://japansociety.org/events/crash-course-for-travelers-to-japan-march-30/) | Classes that try the exercise and first-time downloads from a classroom-specific QR link. |
| **7. App Store editorial** | For the next substantial release, nominate the face-to-face travel experience for US editorial consideration. Supply the real two-person demo, the release date and what changed. Give Apple at least two weeks’ lead time. [Apple featuring nominations](https://developer.apple.com/app-store/getting-featured/) | If featured, record the placement dates and compare US App Store Browse first-time downloads with the preceding week. Treat any lift as directional. |

**How to choose the next test.** If there is no suitable Seats.aero slot, start with the study-abroad slide alongside the search guide. At 7 and 14 days, record placements actually published, outbound visits, first-time downloads and hours spent. As an initial rule, try a second placement when the first yields at least five reported first-time downloads for four staff hours or less. Give search its four-week window. If clicks arrive but downloads stay unreported, check the link, traffic volume and destination before expanding. Review available subscription results at day 35.

Use a distinct App Store Connect campaign link for each channel and placement, pointing to the matching custom product page where appropriate. Apple credits a first-time download within 24 hours of a campaign-link visit and shows a campaign after five individual users have downloaded. Record smaller cohorts as **unreported**. Use the link’s App Store Connect metrics for organic acquisition and subscriptions where available. The broker’s keyword-to-Pro report measures Apple Ads. [Apple campaign links](https://developer.apple.com/help/app-store-connect-analytics/acquisition/campaign-links) · [Custom product pages](https://developer.apple.com/app-store/custom-product-pages/)

## Storefronts, positioning and later channels

All five campaigns use the **US storefront**, with English ad copy and English bid keywords. There is no device-language restriction, and Discovery can match additional search terms. Japan, Taiwan and Hong Kong are expansion candidates. Use the US results and the readiness of localized onboarding and listings to decide whether to test another storefront.

For travel creative, lead with two people sharing one phone, automatic language detection, face-to-face reading and a bilingual transcript. Neither person needs AirPods. Check current Apple Translate capabilities before making a comparative language claim. Year-end travel, Lunar New Year and Japan's spring travel season are opportunities for creative once the campaigns are ready.

Travel creator partnerships remain an option once we have a demo and destination page that earn downloads. Paid Meta, TikTok and Google acquisition stays deferred until the US test establishes viable acquisition economics.
