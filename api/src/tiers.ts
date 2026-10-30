// Single source of truth for tier limits (SPEC.md section 7). Prices live in App Store Connect.
const GB = 1024 ** 3;

export const TIERS = {
  taster: { peopleCap: 4, days: 1, storageCapBytes: 1 * GB },
  pocket: { peopleCap: 10, days: 2, storageCapBytes: 5 * GB },
  party: { peopleCap: 25, days: 5, storageCapBytes: 25 * GB },
  festival: { peopleCap: 75, days: 10, storageCapBytes: 100 * GB },
} as const;

export type Tier = keyof typeof TIERS;
