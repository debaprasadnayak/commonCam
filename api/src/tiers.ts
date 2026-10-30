// Single source of truth for tier limits (SPEC.md section 7). Prices live in App Store Connect
// (and, for local testing, ios/CommonCamTests/CommonCam.storekit).
const GB = 1024 ** 3;

export const TIERS = {
  taster: { peopleCap: 4, days: 1, storageCapBytes: 1 * GB, productId: null },
  pocket: { peopleCap: 10, days: 2, storageCapBytes: 5 * GB, productId: "app.commoncam.tier.pocket" },
  party: { peopleCap: 25, days: 5, storageCapBytes: 25 * GB, productId: "app.commoncam.tier.party" },
  festival: { peopleCap: 75, days: 10, storageCapBytes: 100 * GB, productId: "app.commoncam.tier.festival" },
} as const;

export type Tier = keyof typeof TIERS;
export type PaidTier = Exclude<Tier, "taster">;

export function isPaidTier(tier: unknown): tier is PaidTier {
  return tier === "pocket" || tier === "party" || tier === "festival";
}

/** Free Taster groups a device may ever create (SPEC.md section 15: Taster abuse). */
export const TASTER_LIMIT_PER_DEVICE = 1;
