-- One row per App Store transaction that activated a group. The UNIQUE transaction id is what
-- makes replaying a signed transaction fail.
CREATE TABLE orders (
  id TEXT PRIMARY KEY,
  group_id TEXT NOT NULL REFERENCES groups (id),
  apple_transaction_id TEXT NOT NULL UNIQUE,
  sku TEXT NOT NULL,
  amount_milliunits INTEGER,
  currency TEXT,
  credit_applied INTEGER NOT NULL DEFAULT 0,
  environment TEXT,
  created_at TEXT NOT NULL
);
