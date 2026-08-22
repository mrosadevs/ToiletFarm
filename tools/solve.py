"""Solve for rebirth costs that hit a target pacing curve.

First rebirth ~10 minutes, each one after that meaningfully longer.
"""
import math, sim, sweep

# 10 minutes, then x1.5 each time: the "increasingly longer and more difficult" ask
TARGETS = [10, 15, 23, 34, 51, 77, 115, 170]  # minutes

def time_for(rebirths, cost):
    s, _ = sweep.best(rebirths, cost, sim.BUY_PRODUCTION_SECONDS)
    return s

def solve(rebirths, want_seconds, lo, hi):
    """Binary search the cost whose optimal-play time is closest to want_seconds."""
    best_cost, best_err = None, None
    for _ in range(26):
        mid = math.sqrt(lo * hi)          # geometric bisection: costs span decades
        t = time_for(rebirths, mid)
        if t is None:
            hi = mid
            continue
        err = abs(t - want_seconds)
        if best_err is None or err < best_err:
            best_cost, best_err = mid, err
        if t < want_seconds:
            lo = mid
        else:
            hi = mid
    return best_cost

def nice(x):
    """Round to a readable figure: 2 significant digits."""
    if x <= 0:
        return 0
    mag = 10 ** math.floor(math.log10(x))
    return round(x / mag * 10) / 10 * mag

if __name__ == "__main__":
    mults = [e["mult"] for e in sim.REBIRTHS]
    print(f"{'rebirth':>8} {'target':>7} {'solved cost':>18} {'rounded':>18} {'actual':>8}")
    costs = []
    for i, minutes in enumerate(TARGETS):
        want = minutes * 60
        # the multiplier the player carries INTO this run
        lo, hi = 1e3, 1e21
        c = solve(i, want, lo, hi)
        if c is None:
            print(f"{i+1:>8} {minutes:>6}m  unreachable")
            continue
        r = nice(c)
        actual = time_for(i, r)
        costs.append(r)
        print(f"{i+1:>8} {minutes:>6}m {c:>18,.0f} {r:>18,.0f} {sim.fmt(actual):>8}")

    print("\nConfig.REBIRTHS costs:")
    for i, c in enumerate(costs):
        mult = mults[i]
        print(f"  {{ cost = {c:.6g},".ljust(28) + f"mult = {mult},".ljust(14) + "},")
