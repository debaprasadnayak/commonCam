# commonCam: Cost Model

Status: draft. All prices are **indicative**, taken from third-party articles, not official price pages. Verify against the Azure Pricing Calculator and Cloudflare's R2 pricing page before using any number externally. Have Finance review the tier prices.

Reproduce with: `python3 -I cost_model.py` (edit the constants at the top to change assumptions).

## 1. Headline

**Egress (download) cost, not storage, decides the provider.** Each member can bulk-download the full-quality album, so data leaving the cloud is the main cost.

- On **Azure Blob (hot)** at ~$0.087/GB egress, **Party** loses money in the *Typical* scenario and **Festival** loses money in *every* scenario, including *Light*.
- On **Cloudflare R2** (zero egress fees), every tier stays above ~92% margin in every scenario.

**Recommendation:** put the media bucket on R2. This supersedes the earlier "Azure by default" suggestion, which was conditional on this cost check. The API and database can sit on either platform (see ARCHITECTURE.md).

## 2. Inputs

| Input | Value | Source / note |
|---|---|---|
| Azure Blob hot LRS storage | $0.0184 /GB-month | Indicative; sources range ~$0.018 to $0.0208 ([nops](https://www.nops.io/blog/azure-storage-pricing/), [NetApp](https://www.netapp.com/blog/azure-blob-storage-pricing-the-complete-guide-azure-cvo-blg/), [Lucidity](https://lucidity.cloud/feeds/blog/azure-storage-cost)) |
| Azure egress | $0.087 /GB | One source for the first 10 TB; another gives a $0.01 to $0.14 range by region ([nops](https://www.nops.io/blog/azure-storage-pricing/), [Smikar](https://www.smikar.com/azure-blob-storage-pricing)). **Sources conflict; verify.** |
| Azure ops | $5.00 /M writes, $0.40 /M reads | Rough placeholder, not sourced |
| R2 storage | $0.015 /GB-month | [Semaphore](https://semaphore.io/blog/cloudflare-r2%22) and [Spendbase](https://www.spendbase.co/?p=35561) |
| R2 egress | $0 | Same sources |
| R2 ops | $4.50 /M Class A, $0.36 /M Class B | Same sources |
| Functions/API compute | Not modelled separately; folded into $0.03 fixed per group | Azure Functions list price in USD **not verified** (only a GBP reseller figure found in a [G-Cloud pricing document](https://assets.applytosupply.digitalmarketplace.service.gov.uk/g-cloud-15/documents/704379/350008158077504-pricing-document-2026-01-29-1758.pdf)) |
| Apple commission | 15% | Assumes Small Business Program enrolment. Use 30% otherwise (confirm with Finance) |
| Retention | tier days + 14-day grace | Spec allows 14 to 30 days of grace |
| Item size | 4 MB average | Blended HEIC photos and short HEVC clips |
| Preview traffic | 3% of album size per member | Thumbnails served via CDN |

### Usage scenarios

| Scenario | Storage cap used | Members who bulk-download originals |
|---|---|---|
| Light | 40% | 10% |
| Typical | 60% | 25% |
| Heavy | 100% | 50% |

These behaviours are **guesses**. The pilot event (SPEC.md section 14) should replace them with measured data.

## 3. Results (per paid group)

Net revenue is the placeholder price after Apple's 15%.

| Tier (price) | Provider | Scenario | Cost/group | Net revenue | Margin | Egress GB |
|---|---|---|---|---|---|---|
| Pocket ($4.99) | Azure | Light | $0.28 | $4.24 | $3.96 (93%) | 3 |
| Pocket | Azure | Typical | $0.80 | $4.24 | $3.45 (81%) | 8 |
| Pocket | Azure | Heavy | $2.39 | $4.24 | $1.85 (44%) | 26 |
| Pocket | R2 | Light | $0.05 | $4.24 | $4.19 (99%) | 3 |
| Pocket | R2 | Typical | $0.06 | $4.24 | $4.18 (99%) | 8 |
| Pocket | R2 | Heavy | $0.08 | $4.24 | $4.16 (98%) | 26 |
| Party ($9.99) | Azure | Light | $3.00 | $8.49 | $5.49 (65%) | 32 |
| Party | Azure | Typical | $9.38 | $8.49 | **-$0.89 (-10%)** | 105 |
| Party | Azure | Heavy | $29.20 | $8.49 | **-$20.71 (-244%)** | 331 |
| Party | R2 | Light | $0.15 | $8.49 | $8.34 (98%) | 32 |
| Party | R2 | Typical | $0.21 | $8.49 | $8.28 (98%) | 105 |
| Party | R2 | Heavy | $0.33 | $8.49 | $8.17 (96%) | 331 |
| Festival ($24.99) | Azure | Light | $34.75 | $21.24 | **-$13.51 (-64%)** | 390 |
| Festival | Azure | Typical | $110.84 | $21.24 | **-$89.60 (-422%)** | 1,260 |
| Festival | Azure | Heavy | $347.84 | $21.24 | **-$326.60 (-1538%)** | 3,975 |
| Festival | R2 | Light | $0.69 | $21.24 | $20.55 (97%) | 390 |
| Festival | R2 | Typical | $1.03 | $21.24 | $20.22 (95%) | 1,260 |
| Festival | R2 | Heavy | $1.69 | $21.24 | $19.55 (92%) | 3,975 |

The Free Taster (4 people, 1 day, 1 GB) costs well under $0.05 per group on R2, which is the acquisition cost of the free tier. Not modelled in the script; add it before launch.

## 4. Caveats and risks

- **R2 margins look very high because the model counts only infrastructure.** It excludes development, support, refunds, chargebacks, Apple tax edge cases, moderation, legal and marketing.
- **Free Taster abuse:** it is anonymous and free, so a farm of free groups is a cost risk. Mitigate with per-device limits and a Taster storage cap.
- **Egress assumptions are the biggest uncertainty.** If R2 pricing or terms change, or heavy video use exceeds the model, revisit. Cloudflare's terms for large media workloads should be read before committing.
- **Mitigations if staying on Azure:** serve compressed previews by default, make full-resolution download an explicit action, rate-limit bulk download, or price egress into the tiers.
- **Add-on SKUs** (+day, +10 GB, +10 people) have the same cost drivers; +10 GB adds roughly $0.02 to $0.05 on R2.
- **Not verified:** Azure Functions USD pricing, Cloudflare Workers/D1/Queues pricing, and storage redundancy options.

## 5. Next steps

1. Verify every input against official price pages.
2. Add the Taster and add-ons to the script.
3. Replace guessed behaviour (item size, download share) with pilot data.
4. Finance to review tier prices and the Apple commission assumption.
