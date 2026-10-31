-- Upload reservations (security fix SEC-01): a 'pending' (or 'confirming') item reserves its bytes against the
-- group's storage cap until reserved_until. Uploads must finish before then; the hourly lifecycle job expires
-- the rest (deletes their R2 objects, aborts multipart uploads, removes the rows).
ALTER TABLE items ADD COLUMN reserved_until TEXT;
UPDATE items SET reserved_until = strftime('%Y-%m-%dT%H:%M:%fZ', created_at, '+1 day') WHERE status IN ('pending', 'confirming');
