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
- The transaction's App Store `environment` must equal `APP_STORE_ENV` in `api/wrangler.jsonc` (otherwise 403). It is `Sandbox` for the dev Worker; set it to `Production` for the launch (production) Worker so Sandbox purchases can't activate real groups.
- Purchases made against the local `.storekit` file are signed by Xcode, not Apple, so `npm run dev` rejects them (403); the purchase stays unfinished in StoreKit. End-to-end activation needs App Store Connect sandbox products.

## Continuous integration

CI runs on pushes to `main`, on non-draft pull requests to `main`, and on demand. Draft PRs and pushes to other branches don't trigger it, because the iOS job runs on macOS and macOS minutes count 10× against the Actions quota. Run the tests locally while building, and start CI on a branch with `gh workflow run CI --ref <branch>` when you need it. A newer run on the same ref cancels the older one, and changes to docs alone don't trigger CI.

## Cloudflare dev deployment

The `deploy-dev` GitHub Actions job deploys the API to `commoncam-api-dev` on pushes to `main` (or a manual run of the CI workflow), after the Worker API tests pass, applying any new D1 migrations to the remote `commoncam` database first. Configure these repository Actions secrets before merging or pushing the workflow to `main`:

- `CLOUDFLARE_API_TOKEN`: a token with Workers Scripts:Edit and D1:Edit on this account (the job applies D1 migrations before deploying).
- `CLOUDFLARE_ACCOUNT_ID`: the Cloudflare account ID.
- `MEDIA_SIGNING_KEY`: a private signing key for media URLs; use a strong random value and do not commit it.
- `APNS_PRIVATE_KEY` (optional until an Apple team exists): the APNs `.p8` key; see Push notifications below.

The dev Worker uses the `commoncam` D1 database and private `commoncam-media` R2 bucket. The `commoncam-events` Queue is provisioned but is not yet bound to the Worker. The hourly cron trigger for the lifecycle job (below) is declared in `api/wrangler.jsonc` and deployed with the Worker.

## Group lifecycle: expiry, grace, deletion

`api/src/lifecycle.ts` runs hourly (cron `0 * * * *` in `api/wrangler.jsonc`, `scheduled` handler in `api/src/index.ts`):

1. **Active → Grace** when `ends_at` passes. `grace_ends_at = ends_at + GRACE_DAYS` (one value in `vars` in `api/wrangler.jsonc`, default `14`). Grace groups are read-only: every upload endpoint answers 410, galleries and downloads keep working.
2. **Grace → Deleted** when `grace_ends_at` passes: unfinished multipart uploads are aborted, every R2 object under `groups/<groupId>/` is deleted, the prefix is listed again to check it is empty, then the group's items, multipart rows, reports, blocks, sent-notification records and members are deleted and the group row is kept as a `Deleted` tombstone (orders still reference it; the anonymous `daily_stats` counts are untouched). Each deletion writes a row to the `deletions` table (`objects_deleted`, `objects_remaining` = 0, `items_deleted`, `deleted_at`) as the audit record. If objects remain, the group stays in Grace and the next run retries.
3. **Grace → Active** when the host buys the `app.commoncam.extension` consumable for the group (StoreKit `appAccountToken` = group id): `POST /groups/:id/extend {"signedTransaction"}`, verified and recorded in `orders` like upgrades/add-ons (each transaction once). The group reopens for 7 days from now (`EXTENSION` in `api/src/tiers.ts`).

The same job also **expires abandoned uploads**. Requesting an upload (`POST /groups/:id/uploads` or `/multipart`) reserves its bytes: it is refused with 413 unless ready bytes + every unconfirmed upload + the new one fit the group's cap (one conditional D1 insert, so concurrent requests can't overshoot). A single-PUT reservation lasts 1 hour (its URL 15 minutes); a multipart one 24 hours, renewed by each part plan or completion. Byte PUTs, part uploads, completion and confirm are refused once it has lapsed (410 for signed URLs, 404 for API calls; the app's upload queue then starts the shot over). Each run marks lapsed reservations expired, aborts their multipart upload, deletes their R2 object and rows, and clears the group's `storage_full` flag (`api/src/reservations.ts`). If R2 refuses to assemble a multipart upload, its reservation is released the same way (409).

### R2 lifecycle rule (backstop, configure manually)

The scheduled job is the primary deletion mechanism. As a backstop in case it stops running, add two lifecycle rules to the `commoncam-media` bucket (Cloudflare dashboard → R2 → `commoncam-media` → Settings → Object lifecycle rules, or with Wrangler while logged in to the account):

```sh
npx wrangler r2 bucket lifecycle add commoncam-media expire-group-media groups/ --expire-days 90
npx wrangler r2 bucket lifecycle add commoncam-media abort-stale-multipart groups/ --abort-multipart-days 2
```

- 90 days comfortably exceeds the longest normal life of an upload (Festival 10 days + grace, now 14 days, at most 30). Media in a group the host keeps extending for more than 90 days after upload would be removed by this rule; raise it if extensions should last longer.
- The repository does not configure these rules; CI only deploys the Worker.

## Push notifications (APNs)

The Worker sends (`api/src/push.ts`, sender in `api/src/apns.ts`):

- **Grace reminders** to the host and active members, from the hourly lifecycle job: when the group expires (enters Grace), 7 days and 1 day before its media is deleted. Each fires once per grace period (`notifications_sent`, keyed by group, kind and `grace_ends_at`; a paid extension starts a new one). If runs were missed, only the most urgent due reminder goes out.
- **Storage warnings** to the host and co-hosts when storage crosses into 80% (`nearlyFull`) or 100% (`full`), once per level; the level is re-armed when an upgrade, add-on or deletion brings usage back below it.

The app asks for notification permission at launch and sends its APNs device token to `PUT /devices/push-token {"token":"<hex>"}` (stored per device identity in `push_tokens`). Devices without permission have no token and are skipped; tokens APNs reports as dead are forgotten.

APNs uses token auth (ES256 JWT signed with a `.p8` key). Until it is configured the Worker logs `push: APNs not configured` and sends nothing. To turn it on (needs an Apple Developer team):

1. Create an APNs key in the Apple Developer portal (Keys → Apple Push Notifications service) and enable Push Notifications on the `app.commoncam.CommonCam` App ID.
2. Add to `vars` in `api/wrangler.jsonc`: `"APNS_KEY_ID": "<key id>"`, `"APNS_TEAM_ID": "<team id>"`, and `"APNS_ENV": "production"` for App Store/TestFlight builds (any other value, or none, uses the sandbox for development builds).
3. Add the `.p8` file's contents as the repository Actions secret `APNS_PRIVATE_KEY`; the `deploy-dev` job then runs `wrangler secret put APNS_PRIVATE_KEY` (the step is skipped while the secret is absent). Manually: `npx wrangler secret put APNS_PRIVATE_KEY --name commoncam-api-dev < AuthKey_XXXX.p8`.

The app's `ios/CommonCam.entitlements` has `aps-environment` = `development`; distribution signing switches it to production.

## Analytics

Anonymous and aggregated only (no ad or tracking SDKs): the API counts groups created, uploads and uploaded bytes per UTC day and tier in the D1 table `daily_stats`, with no device, member or group ids, so counts survive group deletion. Report (groups created, uploads, conversion, estimated cost per group, per tier and overall):

```sh
cd api && npx wrangler d1 execute commoncam --remote --file reports/analytics.sql   # dev; needs CLOUDFLARE_API_TOKEN/ACCOUNT_ID
cd api && npx wrangler d1 execute DB --local --file reports/analytics.sql           # local `npm run dev` data
```

Cost per group is an estimate from COST_MODEL.md's R2 unit prices, not billing data; see the comments in `api/reports/analytics.sql`.
