"""Simulate a run of Toilet Farm against the real ToiletConfig formulas.

Models a player who buys whenever a slot is free and affordable and merges every
triple (the Merge All pad). Processing is ignored as a bottleneck on purpose:
EconomyService.processRate floors the drain at produced * (1 + level), so at level 0
the queue already keeps pace with production and cash/sec == production * meter.
"""
import math

MERGE_COUNT = 3
INCOME_RATIO = 3.6
BASE_INCOME = 0.5
BASE_COST = 10.0
MAX_TIER = 30
BUY_SCALE_COEFF = 0.4366
BUY_SCALE_EXPONENT = 0.871
BUY_PRODUCTION_SECONDS = 120.0
BUY_PRODUCTION_BATCH = 100.0

# weighted mean of the flush meter table
_METER = [(0.5, 10), (0.75, 15), (1.0, 30), (1.25, 20), (1.5, 15), (2.0, 10)]
METER_AVG = sum(m * w for m, w in _METER) / sum(w for _, w in _METER)

REBIRTHS = [
    dict(cost=300e3,   mult=2),
    dict(cost=20e6,    mult=5),
    dict(cost=1.25e9,  mult=12),
    dict(cost=80e9,    mult=30),
    dict(cost=5e12,    mult=80),
    dict(cost=330e12,  mult=220),
    dict(cost=20e15,   mult=650),
    dict(cost=1.35e18, mult=2000),
]

def income_per_second(tier):
    return BASE_INCOME * INCOME_RATIO ** (tier - 1)

def buy_cost(tier):
    return BASE_COST * 3.3 ** (tier - 1)

def merge_equivalents(counts):
    return sum(n * MERGE_COUNT ** (t - 1) for t, n in counts.items())

def buy_cost_for(tier, total_equiv, poop_rate_base):
    markup = 1 + BUY_SCALE_COEFF * max(total_equiv, 0) ** BUY_SCALE_EXPONENT
    curve = buy_cost(tier) * markup
    floor = 0.0
    if poop_rate_base > 0:
        floor = poop_rate_base * BUY_PRODUCTION_SECONDS / BUY_PRODUCTION_BATCH
    return math.floor(max(curve, floor))

def plot_slots(rebirths):
    return min(24 + 2 * rebirths, 48)

def max_buy_tier(rebirths):
    return max(1, min(2 * rebirths, MAX_TIER))

def run(rebirths, target, rebirth_costs=None, dt=1.0, cap_seconds=60 * 60 * 24):
    """Seconds for a fresh post-rebirth farm to reach `target` cash."""
    mult = 1.0 if rebirths == 0 else (rebirth_costs or REBIRTHS)[min(rebirths, len(REBIRTHS)) - 1]["mult"]
    slots = plot_slots(rebirths)
    tier = max_buy_tier(rebirths)
    counts = {}
    cash = 10.0
    t = 0.0

    while t < cap_seconds:
        # production, in cash per second
        rate_base = sum(n * income_per_second(k) for k, n in counts.items())
        cash += rate_base * mult * METER_AVG * dt
        if cash >= target:
            return t
        t += dt

        # merge every triple, lowest first, cascading upward
        changed = True
        while changed:
            changed = False
            for k in sorted(list(counts.keys())):
                if k < MAX_TIER and counts.get(k, 0) >= MERGE_COUNT:
                    made = counts[k] // MERGE_COUNT
                    counts[k] -= made * MERGE_COUNT
                    if counts[k] == 0:
                        del counts[k]
                    counts[k + 1] = counts.get(k + 1, 0) + made
                    changed = True

        # buy while there is room and money
        for _ in range(200):
            placed = sum(counts.values())
            if placed >= slots:
                break
            price = buy_cost_for(tier, merge_equivalents(counts), rate_base * mult)
            if cash < price:
                break
            cash -= price
            counts[tier] = counts.get(tier, 0) + 1
    return None

def fmt(seconds):
    if seconds is None:
        return "  > 24h"
    if seconds < 90:
        return f"{seconds:5.0f}s"
    if seconds < 5400:
        return f"{seconds/60:5.1f}m"
    return f"{seconds/3600:5.1f}h"

if __name__ == "__main__":
    print(f"flush meter averages {METER_AVG:.4f}\n")
    print("CURRENT costs -- time for each rebirth, starting fresh from the one before:")
    total = 0.0
    for i, e in enumerate(REBIRTHS):
        s = run(i, e["cost"])
        total += s if s else 0
        print(f"  rebirth {i+1}: cost ${e['cost']:>12,.0f}  mult x{e['mult']:<5}  ->{fmt(s)}"
              f"   (cumulative {fmt(total) if s else 'n/a'})")
