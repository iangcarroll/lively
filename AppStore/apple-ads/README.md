# US Apple Ads search results test

Use [us-campaigns.xlsx](us-campaigns.xlsx) to stage the five campaigns in
[the paid marketing plan](https://github.com/iangcarroll/lively/pull/17).
All campaigns and ad groups start paused. The amounts below assume a USD
Apple Ads account and are proposed starting bids and budgets.

| Campaign | Average USD/day | Ad groups | Max USD/tap |
| --- | ---: | --- | ---: |
| Brand | 4 | Brand | 0.50 |
| Category | 12 | Conversation, Offline | 1.00, 0.85 |
| Language pair | 24 | Japanese, Chinese | 1.10 |
| Competitor | 4 | Other translators | 0.65 |
| Discovery | 11 | Broad, Search Match | 0.70 |

The daily budgets total $55 across campaigns, or a nominal $1,540 over
28 days. Each daily budget is an average. Set the flight dates and check
cumulative spend against the four-week budget before enabling the campaigns.
The settings workbook uses the account's currency. Convert its budgets and
bids before import if the account uses another currency.

## Stage campaigns and keywords

1. In Apple Ads Advanced, open the Cautela campaign group and upload the
   workbook under Campaigns → Actions → Upload Data. Keep the new campaigns
   paused while loading keywords and assigning approved product pages.
2. Download Campaign, Ad Group, and Ad Settings from that campaign group.
   Export the `Settings` worksheet to UTF-8 CSV. From the repository root run
   `python3 Tools/apple-ads/keywords.py settings.csv uploads`. The command
   matches Lively's campaign and ad group names to Apple's assigned IDs, uses
   the exported group's Default Max Bid in account currency, and reads the
   terms from [us-search.json](us-search.json).
3. Upload each `<group> - <id>.csv` in that group's Keywords tab. Upload
   `discovery-negatives.csv` under Discovery's campaign-level Negative
   Keywords. Every exact-match target is excluded from both Discovery groups.
   Only the Search Match group has automatic matching enabled. The Broad group
   uses the three explicit broad seeds.
4. Verify the uploaded rows in Apple Ads. The files create new entities.
   If an upload partly succeeds, download the current settings or keywords
   and retry only the missing rows. Select flight dates and eligible creative
   before enabling delivery.

Apple provides the [campaign workbook](https://ads.apple.com/app-store/help/campaigns/0089-make-edits-in-bulk),
[keyword CSV](https://ads.apple.com/app-store/help/keywords/0014-add-and-manage-keywords),
and [negative keyword CSV](https://ads.apple.com/app-store/help/keywords/0060-use-negative-keywords) specifications.

## US product pages

| Ad group | App Store Connect custom product page | Status on November 19, 2026 |
| --- | --- | --- |
| Conversation | Face-to-face conversations | Waiting for Review |
| Offline | Offline travel translation | Waiting for Review |
| Japanese | Japanese for your trip | Prepare for Submission |
| Chinese | English and Chinese conversations | Prepare for Submission |

The import leaves the custom ad fields empty. Assign these pages when Apple
offers them as eligible ad variations. Use the default listing for Brand,
Other translators and Discovery. [Manage Lively's product pages](https://appstoreconnect.apple.com/apps/6835590432/distribution/productpages).

The Japanese and Chinese pages lead with the English/Japanese Kyoto train
conversation and the English/Traditional Chinese Taipei ticket conversation,
respectively. Both are iPhone captures of Lively's scripted demo. The same
captures appear in the corresponding localized listing artwork.

## Launch baseline and first weekly read

Lively 0.1 launched on November 19, 2026. On launch day the latest date in
App Store Connect Analytics was November 18. The day 1, 7 and 35 download-to-paid
cohorts had insufficient data. Leave the organic baseline blank until Apple
reports post-launch first-time downloads and paid conversions.
[Lively Analytics](https://appstoreconnect.apple.com/apps/6835590432/analytics/overview)

For each keyword, use tap-through **new downloads**, taps and spend from
Apple Ads to calculate tap-to-new-download rate and cost per new download.
The first-conversation, paywall-view and verified first-paid-subscription
rates still need app and broker measurement. Keep missing counts blank.
Evaluate the plan's ~$28 cost-per-subscriber target on measured paid conversions.
Pause at ~$40 spend with zero installs or ~150 installs with zero subscribers
once the conversion window has elapsed. Review cumulative spend separately
from these keyword-level decisions.
