"""commonCam cost model: unit economics per paid group, per tier.

All prices are INDICATIVE (third-party sources, see COST_MODEL.md). Edit the
constants below and re-run:  python3 -I cost_model.py
"""

# ---- Tiers (placeholder prices; see SPEC.md section 7) ----------------------
TIERS = {
    #            people, days, storage GB, price USD
    "Pocket":   (10,  2,   5,  4.99),
    "Party":    (25,  5,  25,  9.99),
    "Festival": (75, 10, 100, 24.99),
}

# ---- Provider assumptions (USD, indicative) ---------------------------------
PROVIDERS = {
    #             storage $/GB-month, egress $/GB, $/million writes, $/million reads
    "Azure Blob (hot, LRS)": (0.0184, 0.087, 5.00, 0.40),
    "Cloudflare R2":         (0.0150, 0.000, 4.50, 0.36),
}

# ---- Usage assumptions ------------------------------------------------------
GRACE_DAYS = 14          # read-only download window after expiry (spec: 14-30)
AVG_MB_PER_ITEM = 4.0    # blended HEIC photo (~3 MB) and short HEVC clip
PREVIEW_FRACTION = 0.03  # thumbnails/previews served as share of album size, per member
SCENARIOS = {
    # utilisation of the storage cap, share of members who bulk-download originals
    "Light":   (0.40, 0.10),
    "Typical": (0.60, 0.25),
    "Heavy":   (1.00, 0.50),
}

# ---- Platform / fixed ------------------------------------------------------
APPLE_COMMISSION = 0.15  # Small Business Program rate; use 0.30 if not enrolled
FIXED_PER_GROUP = 0.03   # functions, DB, notifications, expiry job (rough)


def group_cost(tier, provider, scenario):
    people, days, cap_gb, _ = TIERS[tier]
    storage_rate, egress_rate, write_rate, read_rate = PROVIDERS[provider]
    util, dl_share = SCENARIOS[scenario]

    used_gb = cap_gb * util
    items = used_gb * 1024 / AVG_MB_PER_ITEM
    retention_months = (days + GRACE_DAYS) / 30.0

    storage = used_gb * storage_rate * retention_months
    egress_gb = used_gb * people * dl_share + used_gb * PREVIEW_FRACTION * people
    egress = egress_gb * egress_rate
    ops = (items / 1e6) * write_rate + (items * people * 0.5 / 1e6) * read_rate
    return storage + egress + ops + FIXED_PER_GROUP, egress_gb


def main():
    print("| Tier | Provider | Scenario | Cost/group | Net revenue | Margin | Egress GB |")
    print("|---|---|---|---|---|---|---|")
    for tier, (_, _, _, price) in TIERS.items():
        net = price * (1 - APPLE_COMMISSION)
        for prov in PROVIDERS:
            for scen in SCENARIOS:
                cost, egress_gb = group_cost(tier, prov, scen)
                margin = net - cost
                print(f"| {tier} | {prov} | {scen} | ${cost:.2f} | ${net:.2f} | "
                      f"${margin:.2f} ({margin / net:.0%}) | {egress_gb:.0f} |")


if __name__ == "__main__":
    main()
