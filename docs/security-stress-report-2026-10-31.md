# commonCam security and stress-test report

Date: 2026-10-31 (local time, UTC+01:00).
Revision: `ad80937887ed58b748b144f96c09e09b75871e04`.

## Assessment scope

Testing used isolated Cloudflare Workers, D1 and R2 bindings through the existing Vitest setup on macOS. No requests were sent to the deployed Worker, real App Store services or production storage. All identities and media used in stress tests were synthetic. The test signing certificate is the repository's existing fake App Store PKI.

The source review covered current backend security-sensitive entrypoints and targeted iOS identity, upload, purchase, gallery/download, local cleanup and push-registration flows. It was not a line-by-line audit of every UI or rendering file.

The existing API suite passes all 200 tests in 19 files. The Swift package passes all 127 tests in 22 suites. The new, opt-in stress suite passes 11 checks and fails 4 checks that expose defects. These failures remain reproducible; application code has not been changed.

This is a bounded local resilience test, not a production capacity certification. It does not measure internet latency, Cloudflare account limits, real D1/R2 contention, sustained resource exhaustion, physical iPhone thermal/memory pressure or UI responsiveness. No simulator app tests, live purchase tests, APNs delivery tests or external dependency advisory scan were run.

## Security findings and criticality

Two security vulnerabilities were identified: both MEDIUM. No CRITICAL or HIGH vulnerability was confirmed within the reviewed scope. This is not a guarantee that none exists. The four failing stress checks include one of these security vulnerabilities plus three resilience/reliability defects; they are not four separate security vulnerabilities.

| # | Severity | File | Lines | Vulnerability | Confidence |
|---|----------|------|-------|---------------|------------|
| 1 | 🟡 MEDIUM | [media.ts](../api/src/media.ts#L126) | 126-135, 71-75, 157-179 | Pending uploads bypass billable storage entitlement | 10/10 |
| 2 | 🟡 MEDIUM | [appStore.ts](../api/src/appStore.ts#L86), [purchases.ts](../api/src/purchases.ts#L16) | 86-93; 16-28 | Original purchase transaction remains redeemable after refund | 9/10 |

MEDIUM indicates a meaningful entitlement, financial, or request-resilience defect with prerequisites or limited demonstrated impact. LOW indicates a recoverable reliability defect. A higher severity would require evidence of greater impact than these tests and the source review establish.

### SEC-01: Pending uploads bypass billable storage entitlement

This is the same defect as ST-01 below, not an additional issue. An attacker needs host or active-member access to an active group; a free Taster is sufficient. There is no capacity reservation between issuing the upload capability and storing the bytes. Concurrency is not required if the attacker simply avoids confirming uploads.

Fix before public launch: reserve and enforce pending storage capacity, invalidate expired capabilities, and clean abandoned objects.

### SEC-02: A refunded purchase can still activate a paid group

Severity: MEDIUM. Confidence: 9/10. Source-confirmed; no live Apple refund replay was attempted.

The verifier checks the `revocationDate` in the historical client-submitted signed transaction. It does not obtain the current transaction state from Apple. A purchaser who keeps an original signed transaction, receives an approved refund before redeeming it, and then submits that original transaction can pass the embedded revocation check. The original signed payload does not acquire a later revocation field.

The attack requires possession of an original transaction whose ID has never been redeemed, an approved refund and certificates still within validity. Signature verification, bundle/environment checks and unique transaction IDs remain valuable protections, but do not establish the payment's current state.

Impact: a paid group can be activated using a refunded payment.

Fix before public launch: verify current transaction state before granting the entitlement. Process authenticated App Store refund/revocation notifications, retaining revocations even when the transaction has not yet been redeemed. Define how to handle Apple API unavailability explicitly rather than silently granting an entitlement.

Acceptance: a cryptographically valid but refunded, previously unused transaction cannot activate a paid group; valid non-refunded purchases still succeed; duplicate redemption remains rejected. Include refund-before-redemption, notification-before-redemption, duplicate and out-of-order notification cases.

## Recommended fix order

1. SEC-01 / ST-01: close the storage-entitlement bypass and clean abandoned uploads.
2. SEC-02: check current payment revocation/refund state before activation.
3. ST-03: reject invalid JSON shapes consistently across API routes.
4. ST-02: make invite/PIN attempt limits atomic.
5. ST-04: make confirmation retries converge on an explicit successful or retryable result.

No fixes, commits, deployments or tracking tickets were created as part of this assessment.

## Stress-test findings

### ST-01: Pending media can exceed the storage cap

Severity: MEDIUM. Confidence: 10/10. Reproduced.

A group member can request many upload tickets while `storage_used_bytes` remains unchanged, upload all the objects and leave them unconfirmed. The cap applies when confirming items, after R2 has already accepted the bytes.

The test reduced a synthetic group's cap to 8 bytes to demonstrate the accounting defect without uploading large amounts of data:

- 32 concurrent tickets, each announcing 1 byte, were accepted.
- All 32 PUTs succeeded and R2 contained 32 bytes, four times the cap.
- Confirmation accepted 8 items and refused 24 with HTTP 413.
- Accounted usage remained 8 bytes despite 32 bytes physically stored.

The confirmation transaction protects ready-item accounting but does not protect actual storage consumption. The test establishes the cap bypass at small scale; it does not claim that a real storage bill or platform outage occurred.

Fix: atomically reserve pending bytes before issuing a ticket; include reservations in cap checks; release reservations on abort, expiry and failed completion. Expire unfinished uploads and remove their objects. PUTs and multipart completion must verify the reservation is still valid. Test both upload modes, reservation races and cleanup.

Acceptance: pending plus ready storage cannot exceed the configured budget, except for a separately documented, bounded temporary allowance; failed confirmations cannot leave unbounded unaccounted objects.

### ST-02: Concurrent requests bypass the invite-guessing limit

Severity: MEDIUM. Confidence: 10/10. Reproduced.

From one synthetic IP, 32 simultaneous invalid invite guesses using different device tokens all returned HTTP 404. None returned HTTP 429.

The sequential control from a separate synthetic IP behaved as intended: the first 10 guesses returned 404 and the remaining 22 returned 429. This isolates a concurrency defect rather than an absent limiter.

Fix: make checking and consuming the per-IP allowance atomic, using one conditional database operation or a suitable serialized/rate-limiting service. Apply the same protection to PIN joins. Keep limits independent of caller-controlled device identity.

Acceptance: a 32-request burst in a fresh window admits at most 10 guesses and rejects the remainder, including across simultaneous requests and different device tokens. A local race does not establish real-world PIN compromise or guess throughput.

### ST-03: JSON `null` produces uncaught request exceptions

Severity: MEDIUM. Confidence: 10/10. Reproduced.

The malformed-input matrix exercised seven JSON bodies against six routes, for 42 requests. Thirty-six produced ordinary client errors (24 HTTP 400 and 12 HTTP 404). JSON `null` produced an uncaught TypeError on every route:

| Route | Property access that threw |
|---|---|
| `POST /groups` | `tier` |
| `POST /join` | `pin` |
| `POST /groups/:id/uploads` | `bytes` |
| `POST /groups/:id/items` | `filterRecipe` |
| `POST /groups/:id/multipart` | `bytes` |
| `PUT /devices/push-token` | `token` |

The local Worker invocation rejected its promise; the harness records exceptions separately from HTTP status codes. This test did not observe a deployed HTTP 500 response or a persistent process crash.

Fix: validate parsed JSON as a non-null object before reading properties, then validate each field. Return repository-standard client errors and cover all JSON routes with the same shape tests. Parsing successfully is insufficient: TypeScript generics do not validate runtime JSON.

Acceptance: null, arrays, primitive values and malformed JSON return explicit 4xx responses without uncaught exceptions.

### ST-04: Simultaneous confirmation retries return transient conflicts

Severity: LOW. Confidence: 10/10. Reproduced reliability issue.

Twenty-four simultaneous confirmations of one uploaded item returned 1 HTTP 201, 13 HTTP 200 and 10 HTTP 409 responses. The earlier smaller run also reproduced conflicts (8 of 24).

Storage accounting stayed correct at 1 byte, with exactly one gallery item. There is no demonstrated double charge or corruption. The failing assertion checks retry behavior: callers cannot treat every duplicate confirmation as idempotent success.

Source: [confirmation transaction and conflict handling](../api/src/media.ts#L163).

Fix: after losing the conditional claim, return the existing item if it is now ready. For a genuinely in-progress item, use a documented retryable response and make the client retry it safely.

Acceptance: concurrent retries converge on the same item, never double-charge storage and do not leave a successfully uploaded photo appearing failed in the client.

## Measured load results

Read requests listed a single host's groups. Timing includes response JSON consumption and uses the local runtime's millisecond clock.

| Requests | Concurrency | All HTTP 200 | Elapsed ms | Requests/sec | p50 ms | p95 ms | p99 ms |
|---:|---:|---|---:|---:|---:|---:|---:|
| 128 | 1 | Yes | 133 | 962 | 1 | 2 | 2 |
| 128 | 8 | Yes | 71 | 1,803 | 4 | 5 | 5 |
| 128 | 32 | Yes | 63 | 2,032 | 14 | 18 | 18 |
| 128 | 64 | Yes | 90 | 1,422 | 39 | 44 | 45 |
| 1,024 | 128 | Yes | 569 | 1,800 | 59 | 77 | 80 |

These are short in-process bursts. They are unsuitable as production throughput estimates; the expanded run also overlapped the local Swift build.

Other tested behavior:

- A 64-request free-group creation burst at concurrency 32 created one group and rejected the remaining 63 requests with HTTP 403.
- Three independent 24-request join bursts each admitted exactly three guests, preserving the four-person cap including the host.
- Thirty-two 256 KiB objects uploaded and confirmed successfully at concurrency 8 (8 MiB total).
- Sixty-four downloads at concurrency 16 returned HTTP 200 and matched every expected byte (16 MiB total).
- The media transfer scenario completed in 347 ms locally and accounted for exactly 8 MiB.

## Evidence and reproduction

- [Stress test harness](../api/test/stress.audit.ts)
- [Opt-in test configuration](../api/vitest.stress.config.ts)
- [Machine-readable Vitest results](../api/reports/stress-results-2026-10-31.json)
- [Detailed run output, measurements and exceptions](../api/reports/stress-run-2026-10-31.log)

From the repository's API directory, run:

```sh
npm exec -- vitest run --config vitest.stress.config.ts --reporter=default --reporter=json --outputFile=reports/stress-results-2026-10-31.json
```

Exit code 1 is expected while these four defects remain. The harness is excluded from the default test filename pattern, so `npm test` still runs the original suite. The harness uses only test bindings; do not adapt it to a deployed URL without a separate approved test environment and resource budget.

The normal API suite emits an exception from its deliberately induced D1 constraint failure while reporting all 200 tests passed. That baseline output is separate from the null-input failures in the stress suite.

## Remediation

Fixed on branch `fix/security-stress`, one commit per finding. The stress suite now passes all 15 checks (5 consecutive runs plus the recorded run); the [results](../api/reports/stress-results-2026-10-31.json) and [run log](../api/reports/stress-run-2026-10-31.log) above were regenerated from the passing run. The normal API suite passes 225 tests in 22 files and the Swift package 130 tests.

| Finding | Commit | Fix | Tests |
|---|---|---|---|
| SEC-01 / ST-01 | `fa05ce2` | Upload tickets and multipart starts reserve their bytes with one conditional D1 insert (ready + reserved + new ≤ cap). PUTs, part uploads, completion and confirm need a live reservation (1 h single, 24 h multipart, renewed by plan/complete). The hourly job expires lapsed ones (abort multipart, delete R2 object and rows, clear `storage_full`); R2 assembly failures release theirs. The iOS queue restarts a shot whose upload the server expired. | `api/test/uploadReservations.test.ts`; `UploadQueueTests` (expired upload starts over); stress "does not store pending media beyond a group cap" |
| SEC-02 | `a926eb1` | `POST /app-store/notifications` (V2, chain-verified) records REFUND/REVOKE/REFUND_REVERSED per transaction id, newest `signedDate` wins. Every redemption also asks the App Store Server API for the current state; if Apple can't be asked, Production answers 503 and Sandbox allows with a log line (README). | `api/test/appStoreRevocations.test.ts` |
| ST-03 | `c35d398` | Shared `readJsonObject` (400 for malformed/empty JSON, null, arrays, primitives) used by every JSON route. | `api/test/jsonBodies.test.ts`; stress "returns client errors…" |
| ST-02 | `902e16f` | One conditional insert checks and consumes a guess for both the IP and device keys before the lookup; valid codes and malformed bodies are given back. Applies to QR and PIN. | burst tests in `api/test/join.test.ts` and `api/test/pin.test.ts`; stress "rate-limits a burst of 32 invite guesses" |
| ST-04 | `7765e96` | A confirm that loses the claim returns the ready item (200), or 409 with `Retry-After: 1` while the other confirm is in flight; the upload queue retries 409. | `api/test/media.test.ts` (24 simultaneous confirms); `UploadQueueTests` (409 retried); stress "accounts for one upload once…" |

The stress check "does not store pending media beyond a group cap" was adapted to the fix: tickets beyond the cap are now refused with 413, so the scenario accepts 201 or 413 per ticket and additionally asserts that at most 8 were issued. Its storage assertions are unchanged.
