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
