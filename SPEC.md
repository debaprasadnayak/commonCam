# commonCam: Product Specification (v1 draft)

Status: draft for review. Not yet reviewed by Legal, Finance or the Data Privacy Officer. Companion documents: [ARCHITECTURE.md](ARCHITECTURE.md), [COST_MODEL.md](COST_MODEL.md).

## 1. Summary

commonCam is a paid iOS app. A **host** buys a time-boxed shared album for an event; **guests** join free by scanning the host's QR code, shoot in the in-app camera with trending-style filters, and every capture lands in the shared space tagged by contributor. Participants can copy media to their own device. After the period ends there is a download grace window, then server copies are permanently deleted.

## 2. Goals and non-goals

**Goals:** near-zero-friction joining; best-possible capture quality; a fun, shareable camera; clear contribution attribution; predictable cost for the host; privacy-friendly data lifecycle.

**Non-goals (v1):** Android, web viewer, accounts and logins, public albums, social feed, video editing, App Clip, cloud content scanning.

## 3. Users

- **Host:** creates and pays for the group, controls access.
- **Guest:** joins free, contributes and downloads media.
- Venture context: personal venture. Confirm with Legal that no Capgemini IP or employment policy applies before building.

## 4. Joining and identity

1. Host creates a group and receives a **QR code** (primary) and an optional **6-character PIN** (off by default; no look-alike characters).
2. A guest scans the QR. If the app isn't installed they go to the App Store, install, then rescan or enter the PIN (iOS cannot carry the scan through an install; App Clip is a later improvement).
3. The guest picks a fun display name and accepts a one-tap consent/terms screen. No login or account.
4. Identity is an anonymous random token stored in an **iCloud-synced Keychain** so it survives reinstall or phone change.

**Host controls:** pause joining, rotate QR and PIN, remove or ban members, **approve new members** (optional toggle, applies to QR and PIN), promote a **co-host** as a backup. Join is limited by the tier's people cap and rate-limited against guessing. A QR can be shared or printed; the host's controls are the safeguard.

## 5. Camera and filters

- In-app camera built on **AVFoundation** to capture full-resolution HEIC photos and HEVC video. The system Camera app cannot be intercepted, so quality is matched by using the same capture pipeline.
- Originals are uploaded at full quality. Video is capped at **60 seconds** per clip.
- **~10 to 12 custom filters at launch** (Metal / Core Image: LUT-style looks, grain, vintage, face-based effects), with live preview. The filters are original; Snapchat and Instagram filters themselves cannot be copied. Snap Camera Kit is a possible later option, subject to licensing.
- **Photos are non-destructive**: original plus a filter recipe, so anyone can view or save the original or the filtered version. **Video filters are baked in at capture** in v1, with a clear on/off choice before recording.
- Each capture **auto-saves to the contributor's own Photos library by default** (toggle available). This is a free safety net against deletion and does not count against group storage.

## 6. Shared space

- Each item shows the contributor's fun name and colour; filter by contributor; per-person counts; a lightweight top-contributor highlight (may slip to a later release).
- Any member can save individual items or **bulk-save** to their own Photos.
- Uploads run as persisted, **resumable background uploads** with pending badges so patchy venue Wi-Fi doesn't lose shots.
- Contributors can delete their own uploads; the host can delete anything.

## 7. Pricing and purchasing

Sold through **Apple In-App Purchase** (StoreKit 2). **Prices are placeholders** pending cost modelling (see [COST_MODEL.md](COST_MODEL.md)), Apple's price tiers and Finance review.

| Tier | People | Days | Storage | Placeholder price | Role |
|---|---|---|---|---|---|
| Taster | 4 | 1 | 1 GB | Free | Growth loop; shows the full flow, then hits limits |
| Pocket | 10 | 2 | 5 GB | $4.99 | Deliberately cramped entry |
| **Party** (pre-selected, "most popular") | 25 | 5 | 25 GB | $9.99 | Best-value default |
| Festival | 75 | 10 | 100 GB | $24.99 | Anchor and large events |

- **Add-ons:** +1 day, +10 GB, +10 people, priced so that two or more add-ons approach the next tier's price.
- **Upgrades** mid-event are credit-based: the host pays only the difference.
- Refunds go through Apple's standard process only. Legal and Finance to confirm terms. Apple's commission and tax treatment to be confirmed with Finance.

## 8. Storage cap behaviour

Warnings to the host at **80%** and **100%**. At 100% uploads pause; guests' pending shots stay queued on their phones for **24 hours**; an upgrade or add-on resumes everything automatically. After 24 hours the guest is told clearly.

## 9. Lifecycle after expiry

1. At expiry the album becomes **read-only**, uploads stop.
2. **Grace window of 14 to 30 days** (final value TBD) for bulk-downloading originals. Reminder notifications at 7 days before, 1 day before and at expiry.
3. After the grace window, server copies are **permanently deleted**. Media already saved on a person's device stays there.
4. The host can **pay to extend** or archive.

Rationale for deletion over indefinite retention: it limits storage cost and privacy/GDPR exposure and creates an extension upsell.

## 10. Content safety and privacy (lean v1)

- Terms accepted at join: uploaders and owners are responsible for what they share.
- **Report and block** on every item and member; owner delete and remove; a published contact email for takedown requests.
- Apple's on-device **Sensitive Content Analysis** blurs likely explicit images. Flagged items are hidden pending owner review.
- **Cloud moderation is deferred** unless Legal or App Review requires it.
- Anonymous, aggregated analytics only (groups created, uploads, conversion, cost per group); no ad SDKs and no individual tracking.
- **Needs Legal and the Data Privacy Officer:** whether the lean moderation is sufficient (Apple Guideline 1.2 and operator duties such as notice-and-takedown), consent wording, minors, GDPR and other regimes, retention and deletion commitments, refund terms.

## 11. Technical approach

- iOS: SwiftUI, AVFoundation, Metal, Core Image, StoreKit 2.
- Backend: serverless. Media on **Cloudflare R2** (recommended on cost, see COST_MODEL.md); API and database on Cloudflare (option A) or Azure (option B). Details in [ARCHITECTURE.md](ARCHITECTURE.md).
- Pre-signed direct uploads; lifecycle rules plus scheduled jobs enforce deletion.

## 12. Non-functional requirements (targets to validate)

- Capture-to-gallery visible within a short time on good Wi-Fi; no data loss when offline for the queue window.
- Full-quality originals preserved end to end.
- Costs scale to near zero when idle.
- Deletion at the end of grace is verifiable.

## 13. v1 scope

**In:** create group, QR join (PIN optional), approve members, in-app camera with filters, shared gallery with contributor tags and filter, save and bulk download, Taster plus three paid tiers via IAP, storage-cap handling, expiry and grace with deletion, consent, report and block, owner controls.

**Later:** App Clip, Android guests, add-on SKUs if they slip, top-contributor highlight if it slips, video filter recipes, cloud moderation, Snap Camera Kit.

## 14. Rollout

1. Build the core loop.
2. **TestFlight pilot** at one real small event (e.g. family gathering) to measure upload reliability, real usage (item size, download behaviour) and join friction.
3. Feed measured data into the cost model, adjust tiers, then App Store launch.

## 15. Risks

| Risk | Mitigation |
|---|---|
| Egress cost on the wrong provider turns large tiers loss-making | R2 for media; revisit with pilot data |
| Free Taster abuse | Per-device limits, small cap |
| QR shared beyond intended guests | Approve members, pause, rotate, people cap |
| App Review rejection for UGC | Report, block, filter and contact info in v1; confirm with Legal |
| Filter quality perceived as weaker than Snapchat/Instagram | Focus on a small polished set; consider Camera Kit later |
| Anonymous ban evasion by reinstall | Host-controlled access; rotate QR |
| Pricing psychology unproven | A/B test tiers after pilot |

## 16. Decision log

| # | Decision |
|---|---|
| Venture | Personal; check IP policy with Legal |
| Payer | Host pays; guests free |
| Pricing | Tiered IAP with free Taster, three paid tiers, add-ons, credit upgrades; prices placeholder |
| Camera | AVFoundation in-app, full-quality originals |
| Filters | Custom pack; photos non-destructive, video baked |
| Identity | No login; anonymous device token; iCloud Keychain; co-host |
| Join | QR primary; optional PIN (off by default); approve members toggle |
| Post-expiry | Read-only, grace, permanent server deletion; paid extension |
| Backend | Serverless; R2 for media after cost check; API on Cloudflare or Azure |
| Moderation | Lean v1, Legal to confirm |
| Platform | iOS only; App Clip later |

## 17. Open items

- **Legal / DPO:** items listed in section 10; personal-venture IP check.
- **Finance:** tier prices, Apple commission and tax.
- **Engineering:** verified pricing for Cloudflare Workers/D1/Queues or Azure Functions; Apple transaction validation; resumable upload design.
- **Product:** final grace length, Taster limits, app name.

> This document is a planning draft. Review and validate it with Legal, Finance and the Data Privacy Officer before sharing externally or relying on it for decisions.
