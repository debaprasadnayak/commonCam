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

/** Tiers from smallest to largest; an upgrade only ever moves right. */
export const TIER_ORDER: readonly Tier[] = ["taster", "pocket", "party", "festival"];

/** How much a purchase raises a group's limits. Upgrades, add-ons (and #18's paid extension) all apply one. */
export interface LimitIncrease {
  peopleCap: number;
  days: number;
  storageCapBytes: number;
}

/**
 * Apple can't charge an arbitrary amount, so each (from → to) upgrade is its own consumable priced at
 * the difference between the two tiers (placeholders in CommonCam.storekit).
 */
export function upgradeProductId(from: Tier, to: PaidTier): string {
  return `app.commoncam.upgrade.${from}.${to}`;
}

/** The upgrade a product id stands for, or null if it isn't a valid (smaller → larger) upgrade. */
export function parseUpgradeProductId(productId: string): { from: Tier; to: PaidTier } | null {
  const match = productId.match(/^app\.commoncam\.upgrade\.([a-z]+)\.([a-z]+)$/);
  if (!match) return null;
  const [from, to] = [match[1] as Tier, match[2]];
  if (!TIER_ORDER.includes(from) || !isPaidTier(to)) return null;
  return TIER_ORDER.indexOf(from) < TIER_ORDER.indexOf(to) ? { from, to } : null;
}

export function upgradeIncrease(from: Tier, to: PaidTier): LimitIncrease {
  return {
    peopleCap: TIERS[to].peopleCap - TIERS[from].peopleCap,
    days: TIERS[to].days - TIERS[from].days,
    storageCapBytes: TIERS[to].storageCapBytes - TIERS[from].storageCapBytes,
  };
}

/** Consumable add-ons for paid groups; priced so two or more approach the next tier (SPEC.md section 7). */
export const ADD_ONS = {
  day: { productId: "app.commoncam.addon.day", peopleCap: 0, days: 1, storageCapBytes: 0 },
  storage: { productId: "app.commoncam.addon.storage", peopleCap: 0, days: 0, storageCapBytes: 10 * GB },
  people: { productId: "app.commoncam.addon.people", peopleCap: 10, days: 0, storageCapBytes: 0 },
} as const satisfies Record<string, LimitIncrease & { productId: string }>;

export function addOnForProductId(productId: string): LimitIncrease | null {
  return Object.values(ADD_ONS).find((addOn) => addOn.productId === productId) ?? null;
}
