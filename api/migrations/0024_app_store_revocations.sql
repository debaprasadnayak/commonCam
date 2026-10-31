-- Refunds and revocations reported by App Store Server Notifications V2 (security fix SEC-02), kept whether or
-- not the transaction was ever redeemed, so a refunded purchase can't activate anything later. One row per
-- transaction holding the newest notified state: revoked = 1 after REFUND/REVOKE, 0 after REFUND_REVERSED.
-- signed_date (Apple's notification signedDate, ms) orders out-of-order deliveries; older ones are ignored.
CREATE TABLE app_store_revocations (
  transaction_id TEXT PRIMARY KEY,
  revoked INTEGER NOT NULL,
  notification_type TEXT NOT NULL,
  signed_date INTEGER NOT NULL,
  notification_uuid TEXT,
  updated_at TEXT NOT NULL
);
