-- Host toggle: when 1, new joins (QR or PIN) are stored as status 'pending' until a host or co-host approves.
ALTER TABLE groups ADD COLUMN approval_required INTEGER NOT NULL DEFAULT 0;
