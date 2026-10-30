/**
 * A filter recipe is how a photo should be rendered: `{ id, version, params }`. The app owns the catalogue of
 * filters, so the API only checks the shape (new filters need no API change) and stores it as given.
 */
export interface FilterRecipe {
  id: string;
  version: number;
  params: Record<string, number>;
}

const MAX_PARAMS = 16;

/** `null` = no recipe given; `undefined` = present but malformed. */
export function parseFilterRecipe(value: unknown): FilterRecipe | null | undefined {
  if (value === undefined || value === null) return null;
  if (typeof value !== "object" || Array.isArray(value)) return undefined;
  const { id, version, params } = value as Record<string, unknown>;
  if (typeof id !== "string" || !/^[a-z0-9-]{1,40}$/.test(id)) return undefined;
  if (typeof version !== "number" || !Number.isInteger(version) || version < 1 || version > 1000) return undefined;
  if (typeof params !== "object" || params === null || Array.isArray(params)) return undefined;
  const entries = Object.entries(params);
  if (entries.length > MAX_PARAMS) return undefined;
  if (!entries.every(([key, n]) => /^[a-zA-Z0-9]{1,32}$/.test(key) && typeof n === "number" && Number.isFinite(n))) {
    return undefined;
  }
  return { id, version, params: Object.fromEntries(entries) as Record<string, number> };
}
