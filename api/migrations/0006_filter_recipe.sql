-- Non-destructive photo filters: the original in R2 is never altered; the chosen look is stored as a
-- small JSON recipe {"id","version","params"} set once at confirm time. NULL = shot without a filter.
ALTER TABLE items ADD COLUMN filter_recipe TEXT;
