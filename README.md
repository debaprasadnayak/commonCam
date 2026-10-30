# commonCam

Paid iOS shared-event-album app. Product and design docs: [SPEC.md](SPEC.md), [ARCHITECTURE.md](ARCHITECTURE.md), [COST_MODEL.md](COST_MODEL.md).

## Layout

- `api/`: Cloudflare Worker API (D1 metadata, R2 media). Tier limits live in `api/src/tiers.ts`; D1 schema in `api/migrations/`.
- `ios/CommonCam.xcodeproj`: SwiftUI app (`ios/CommonCam/`) and its simulator tests (`ios/CommonCamTests/`).
- `ios/CommonCamKit/`: Swift package with the app's testable logic (device identity, API client).

## Running locally

Everything runs locally; no Cloudflare account is needed.

```sh
# Worker API (Node 22+)
cd api && npm install
npm test                 # vitest inside the Workers runtime (Miniflare)
npm run dev              # applies D1 migrations locally, serves http://localhost:8787

# Swift package logic
cd ios/CommonCamKit && swift test

# App tests on a simulator
cd ios && xcodebuild test -project CommonCam.xcodeproj -scheme CommonCam \
  -destination 'platform=iOS Simulator,name=iPhone 18 Pro'
```

The app talks to `http://localhost:8787` (set by `APIBaseURL` in `ios/CommonCam-Info.plist`), so run `npm run dev` before launching it in the simulator.

## Purchases (paid tiers)

- Products (placeholder prices) are in `ios/CommonCamTests/CommonCam.storekit`, used by the scheme's Run action and by `StoreKitTest` in `TierPurchaserTests`.
- The API activates a paid group only from an App Store signed transaction that chains to Apple Root CA - G3 (`api/src/appStore.ts`); each transaction id is accepted once. Worker tests use a locally generated stand-in PKI (`api/test/support/fakeAppStore.ts`).
- Purchases made against the local `.storekit` file are signed by Xcode, not Apple, so `npm run dev` rejects them (403); the purchase stays unfinished in StoreKit. End-to-end activation needs App Store Connect sandbox products.

## Cloudflare dev deployment

The `deploy-dev` GitHub Actions job deploys the API to `commoncam-api-dev` on pushes to `main` (or a manual run of the CI workflow), after both test jobs pass, applying any new D1 migrations to the remote `commoncam` database first. Configure these repository Actions secrets before merging or pushing the workflow to `main`:

- `CLOUDFLARE_API_TOKEN`: a token with Workers Scripts:Edit and D1:Edit on this account (the job applies D1 migrations before deploying).
- `CLOUDFLARE_ACCOUNT_ID`: the Cloudflare account ID.
- `MEDIA_SIGNING_KEY`: a private signing key for media URLs; use a strong random value and do not commit it.

The dev Worker uses the `commoncam` D1 database and private `commoncam-media` R2 bucket. The `commoncam-events` Queue is provisioned but is not yet bound to the Worker. The hourly cron trigger for the lifecycle job (below) is declared in `api/wrangler.jsonc` and deployed with the Worker.

## Group lifecycle: expiry, grace, deletion

`api/src/lifecycle.ts` runs hourly (cron `0 * * * *` in `api/wrangler.jsonc`, `scheduled` handler in `api/src/index.ts`):

1. **Active → Grace** when `ends_at` passes. `grace_ends_at = ends_at + GRACE_DAYS` (one value in `vars` in `api/wrangler.jsonc`, default `14`). Grace groups are read-only: every upload endpoint answers 410, galleries and downloads keep working.
2. **Grace → Deleted** when `grace_ends_at` passes: unfinished multipart uploads are aborted, every R2 object under `groups/<groupId>/` is deleted, the prefix is listed again to check it is empty, then the group's items, multipart rows, reports, blocks and members are deleted and the group row is kept as a `Deleted` tombstone (orders still reference it). Each deletion writes a row to the `deletions` table (`objects_deleted`, `objects_remaining` = 0, `items_deleted`, `deleted_at`) as the audit record. If objects remain, the group stays in Grace and the next run retries.
3. **Grace → Active** when the host buys the `app.commoncam.extension` consumable: `POST /groups/:id/extend {"signedTransaction"}` (verified like paid tiers; each transaction once). The group reopens for 7 days (`EXTENSION` in `api/src/tiers.ts`).

### R2 lifecycle rule (backstop, configure manually)

The scheduled job is the primary deletion mechanism. As a backstop in case it stops running, add two lifecycle rules to the `commoncam-media` bucket (Cloudflare dashboard → R2 → `commoncam-media` → Settings → Object lifecycle rules, or with Wrangler while logged in to the account):

```sh
npx wrangler r2 bucket lifecycle add commoncam-media expire-group-media groups/ --expire-days 90
npx wrangler r2 bucket lifecycle add commoncam-media abort-stale-multipart groups/ --abort-multipart-days 2
```

- 90 days comfortably exceeds the longest normal life of an upload (Festival 10 days + grace, now 14 days, at most 30). Media in a group the host keeps extending for more than 90 days after upload would be removed by this rule; raise it if extensions should last longer.
- The repository does not configure these rules; CI only deploys the Worker.
