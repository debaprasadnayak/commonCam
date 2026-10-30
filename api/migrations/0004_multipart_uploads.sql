-- Resumable uploads: an item's original is sent as an R2 multipart upload, one row per item.
-- completed = 1 once R2 has assembled the object; the item is then confirmed via POST /groups/:id/items.
CREATE TABLE multipart_uploads (
  item_id TEXT PRIMARY KEY REFERENCES items (id),
  upload_id TEXT NOT NULL,
  part_size INTEGER NOT NULL,
  part_count INTEGER NOT NULL,
  completed INTEGER NOT NULL DEFAULT 0
);

-- Parts R2 has stored, so a client resuming after a crash or restart can ask which parts are still missing.
CREATE TABLE multipart_parts (
  item_id TEXT NOT NULL REFERENCES multipart_uploads (item_id),
  part_number INTEGER NOT NULL,
  etag TEXT NOT NULL,
  PRIMARY KEY (item_id, part_number)
);
