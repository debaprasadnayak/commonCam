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

The app talks to the dev Worker at `https://commoncam-api-dev.dev094u.workers.dev`. The address comes from the `API_BASE_URL` build setting, which `APIBaseURL` in `ios/CommonCam-Info.plist` reads. To use a local Worker, run `npm run dev` and override the setting, for example by adding `API_BASE_URL=http://localhost:8787` to the `xcodebuild` command.

## Purchases (paid tiers)

- Products (placeholder prices) are in `ios/CommonCamTests/CommonCam.storekit`, used by the scheme's Run action and by `StoreKitTest` in `TierPurchaserTests`.
- The API activates a paid group only from an App Store signed transaction that chains to Apple Root CA - G3 (`api/src/appStore.ts`); each transaction id is accepted once. Worker tests use a locally generated stand-in PKI (`api/test/support/fakeAppStore.ts`).
- Purchases made against the local `.storekit` file are signed by Xcode, not Apple, so `npm run dev` rejects them (403); the purchase stays unfinished in StoreKit. End-to-end activation needs App Store Connect sandbox products.

## Cloudflare dev deployment

The `deploy-dev` GitHub Actions job deploys the API to `commoncam-api-dev` on pushes to `main` (or a manual run of the CI workflow), after the Worker API tests pass, applying any new D1 migrations to the remote `commoncam` database first. Configure these repository Actions secrets before merging or pushing the workflow to `main`:

- `CLOUDFLARE_API_TOKEN`: a token with Workers Scripts:Edit and D1:Edit on this account (the job applies D1 migrations before deploying).
- `CLOUDFLARE_ACCOUNT_ID`: the Cloudflare account ID.
- `MEDIA_SIGNING_KEY`: a private signing key for media URLs; use a strong random value and do not commit it.

The dev Worker uses the `commoncam` D1 database and private `commoncam-media` R2 bucket. The `commoncam-events` Queue is provisioned but is not yet bound to the Worker. Cron triggers remain unconfigured until the API implements a scheduled handler.

## Analytics

Anonymous and aggregated only (no ad or tracking SDKs): the API counts groups created, uploads and uploaded bytes per UTC day and tier in the D1 table `daily_stats`, with no device, member or group ids, so counts survive group deletion. Report (groups created, uploads, conversion, estimated cost per group, per tier and overall):

```sh
cd api && npx wrangler d1 execute commoncam --remote --file reports/analytics.sql   # dev; needs CLOUDFLARE_API_TOKEN/ACCOUNT_ID
cd api && npx wrangler d1 execute DB --local --file reports/analytics.sql           # local `npm run dev` data
```

Cost per group is an estimate from COST_MODEL.md's R2 unit prices, not billing data; see the comments in `api/reports/analytics.sql`.
