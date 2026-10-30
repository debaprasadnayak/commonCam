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
