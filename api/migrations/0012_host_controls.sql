-- Host can stop new joins without rotating the QR. Members.role gains 'co-host'; members.status gains 'removed' and 'banned'.
ALTER TABLE groups ADD COLUMN joining_paused INTEGER NOT NULL DEFAULT 0;
