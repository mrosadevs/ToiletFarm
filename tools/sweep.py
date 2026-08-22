"""Sweep the buy-price knobs and report time-to-first-rebirth for an optimal player.

The player grows the farm for `grow` seconds, then stops buying and banks. Sweeping
`grow` and taking the minimum is a decent stand-in for someone playing sensibly.
"""
import math, sim

def run(rebirths, target, grow, prod_seconds, coeff=None, dt=1.0, cap=60 * 60 * 12):
    mult = 1.0 if rebirths == 0 else sim.REBIRTHS[rebirths - 1]["mult"]
    slots = sim.plot_slots(rebirths)
    # rebirth resets p.buyTier to 1; the ceiling only says how far you MAY raise it
    # at the Upgrade pad during the run, so a fresh run always starts on Tier 1
    tier = 1
    counts, cash, t = {}, 10.0, 0.0
    C = sim.BUY_SCALE_COEFF if coeff is None else coeff

    def price(total_equiv, rate):
        markup = 1 + C * max(total_equiv, 0) ** sim.BUY_SCALE_EXPONENT
        curve = sim.buy_cost(tier) * markup
        floor = rate * prod_seconds / 100.0 if rate > 0 else 0.0
        return math.floor(max(curve, floor))

    while t < cap:
        rate_base = sum(n * sim.income_per_second(k) for k, n in counts.items())
        cash += rate_base * mult * sim.METER_AVG * dt
        if cash >= target:
            return t
        t += dt

        changed = True
        while changed:
            changed = False
            for k in sorted(list(counts.keys())):
                if k < sim.MAX_TIER and counts.get(k, 0) >= 3:
                    made = counts[k] // 3
                    counts[k] -= made * 3
                    if counts[k] == 0:
                        del counts[k]
                    counts[k + 1] = counts.get(k + 1, 0) + made
                    changed = True

        if t <= grow:
            for _ in range(400):
                if sum(counts.values()) >= slots:
                    break
                p = price(sim.merge_equivalents(counts), rate_base * mult)
                if cash < p:
                    break
                cash -= p
                counts[tier] = counts.get(tier, 0) + 1
    return None

def best(rebirths, target, prod_seconds, coeff=None):
    grows = [30, 60, 120, 240, 480, 900, 1800, 3600, 7200, 10**9]
    out = []
    for g in grows:
        s = run(rebirths, target, g, prod_seconds, coeff)
        if s:
            out.append((s, g))
    if not out:
        return None, None
    return min(out)

if __name__ == "__main__":
    print("time to the FIRST rebirth ($300K) as the production floor changes")
    print(f"{'sec/100 toilets':>16} {'best time':>10} {'grow phase':>11}")
    for ps in (300, 150, 60, 30, 10, 3, 0):
        s, g = best(0, 300e3, ps)
        print(f"{ps:>16} {sim.fmt(s):>10} {sim.fmt(g) if g and g < 10**8 else '   always':>11}")
