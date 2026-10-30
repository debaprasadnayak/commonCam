-- Storage cap (#17): set when an upload is refused for lack of room, so the group counts as full (warnings,
-- push) even below 100%; cleared when the storage cap rises or an item is deleted.
ALTER TABLE groups ADD COLUMN storage_full INTEGER NOT NULL DEFAULT 0;
