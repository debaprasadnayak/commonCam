-- Optional 6-character join PIN. NULL means PIN joining is off (the default).
ALTER TABLE groups ADD COLUMN pin TEXT;
CREATE UNIQUE INDEX groups_pin ON groups (pin);
