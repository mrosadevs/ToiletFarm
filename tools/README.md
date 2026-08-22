# Economy tuning model

A simulation of the core loop, used to set `Config.REBIRTHS` costs against a target
pacing curve rather than picking numbers by eye.

```bash
python tools/sim.py      # time per rebirth with the current table
python tools/solve.py    # solve costs for a target pacing curve
python tools/sweep.py    # effect of the buy-price knobs on the first rebirth
```

It models production, merging, the buy curve and the flush meter's weighted average
(1.1375), for a player who grows the farm and then banks. Processing is deliberately
not a bottleneck: `EconomyService.processRate` floors the drain at
`produced * (1 + level)`, so at level 0 the queue already keeps pace and
cash/sec == production * meter.

**What it does not model**, all of which make a real player faster: the Buy Tier
upgrade, the cash/value upgrades, lucky blocks, offline earnings, the group pad and
the cash packs. Treat its numbers as a pacing ceiling, not a promise.

Two findings worth keeping:

- A naive "always buy" player never banks anything, which is why an early run of this
  model reported 22 hours for the first rebirth. Sensible play is grow-then-bank.
- Rebirth resets `buyTier` to 1. The Buy Tier ceiling only says how far you MAY raise
  it during the run, so every run starts buying Tier 1 again.
