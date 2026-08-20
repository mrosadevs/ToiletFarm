# Toilet Farm — session history

A running log, newest session first. One entry per working session: what changed,
what was verified, what was **not** done, and what the next session should pick up.

`ARCHITECTURE.md` describes the current state of the game.
`CLAUDE.md` holds the always-on rules. This file is the timeline.

**Rule for whoever writes here:** record what actually happened, including what was
skipped and why. An entry that only lists wins is worse than no entry — the value of
this file is that the unfinished work stays visible across sessions.

---

## Session 1 — 2026-08-20 · Studio → Rojo migration, then Tier 1 + Tier 2 remediation

**Starting point:** a working Studio-authored place (`toieltfarm.rbxl`, placeId
`130638230805196`), no repo, no Rojo, no version control.

### Done

**Migration** (commit `43b69d2`, a pure-movement diff)

- Extracted all 31 Rojo-owned scripts to `src/`, byte-identical. The place file was
  parsed locally with Lune (`roblox.deserializePlace`) rather than round-tripped
  through Studio MCP.
- Parity proven mechanically: rebuilt the tree with `rojo build` and diffed every
  script source against the original place — **31/31 identical, 0 missing, 0 extra,
  0 differing.**
- Hierarchy reproduced as-is, *not* restructured. The existing layout was already
  close to the standard's shape, and a coherent structure stays.
- Repo scaffolding: `default.project.json`, `rokit.toml` (pinned toolchain),
  `.gitignore`, `.luaurc` (nonstrict), `stylua.toml`, `selene.toml`, `.vscode/`.
- Duplicate-execution hazard checked and **clear** — the mapping is 1:1 onto the
  original locations, so Rojo reconciled in place rather than duplicating. Every
  container count matched; nothing needed deleting.
- Rojo sync verified live in both directions, including deletion propagation.

**Tier 1 — exploitable / lossy** (4 commits)

| Commit | Fix |
|---|---|
| `e4d3304` | Saves now go through `UpdateAsync` with session locking and **deep** snapshots. `table.clone` was shallow, so a mutation during the yielding save wrote torn data; `SetAsync` was a blind overwrite that let two servers roll each other back. |
| `a3363f9` | `ProcessReceipt` is idempotent by `PurchaseId` and only answers `PurchaseGranted` once the grant is confirmed saved. Previously a retry could pay out twice, and a server dying before autosave left a player charged with nothing. |
| `22bddb2` | Banked and queued cash persisted. `pending` / `queuePoops` / `queueCash` were in-memory only, so depositing and logging out mid-processing silently destroyed all of it. |
| `886e3f4` | Free-money chest cooldown moved from `os.clock()` (server uptime) to persisted `os.time()`. Server-hopping reset it instantly. |

**Tier 2 — structural debt** (3 commits)

| Commit | Fix |
|---|---|
| `daf97b3` | Killed a `Player:IsFriendsWith` **web call running at 60 Hz × players²** inside the economy Heartbeat, plus a full per-toilet rate rebuild every frame. Friend counts are cached and refreshed on join/leave; the queue drain ticks at 0.2s with accumulated dt (arithmetically identical payout). |
| `ac99840` | Added `ServerScriptService/Security`: `RateLimiter` (per-player, per-action token buckets) and `RemoteGuard` (rate limit + argument validation + dispatch). All 10 handlers in `Main` plus `RequestState` now route through it. `RedeemCode` throttled to 1 per 5s against enumeration. |
| `1cf3e10` | Declared `AutoMerge` and `ExtendedSeptic`, which live code referenced but `PassService.PASSES` did not contain — silently disabling auto-merge, the AutoMerge pad, and the extended offline cap. Also fixed `DoubleOffline` retrying forever when the player claimed before buying. |

**Documentation** (`25dc6a2`, `bb692d9`) — `ARCHITECTURE.md`, `CLAUDE.md`, stylua
config tuned to the codebase's existing one-line-guard idiom.

### Verified

```text
[x] Backup exists outside the repo, checksum-matched
    ~/Documents/ToiletFarm_Backups/ToiletFarm_pre-migration_2026-08-20.rbxl
    sha1 f83f73a0374281c987544b6d243fe7edd14fe6ad
[x] 31/31 scripts byte-identical after rojo build
[x] No duplicate execution — container counts match $path counts
[x] Rojo sync live both ways, deletions propagate
[x] RateLimiter burst behaviour and every validator exercised in Studio
    (NaN and infinity correctly rejected)
[x] selene: 0 errors. luau-lsp: no diagnostics in any file changed this session
[x] rojo build succeeds
```

### Not done — carry into the next session

1. **No playtest.** This is the big one. Parity is proven *structurally* (identical
   sources, matching tree, clean build) but has **not** been confirmed in gameplay.
   The DataStore read was blocked by the tooling classifier and was not worked
   around; a Studio playtest also writes to the real save under `p_145397307`.
   - Exercise: buy → drop → carry → deposit → queue drain → collect → upgrade → rebirth.
   - Then **rejoin twice** — data loss shows on the second join, and the new session
     locking makes rejoin timing worth watching specifically.
   - Watch Output for anything happening twice.
2. **`AutoMerge` and `ExtendedSeptic` need real gamepass IDs** created on the Roblox
   dashboard. Both sit at id `0`, so auto-merge, that pad, and the extended offline
   cap stay inert until filled in. **This is a dashboard action, not a code change.**
3. **Tier 3 was never started** — deliberately. Not begun: types at the persistence
   boundary (the profile is `any` throughout), `--!strict` per file, tests for the
   deterministic logic (`ToiletConfig` curves, offline maths, `RateLimiter`), CI.
4. **Tree is not StyLua-formatted** — 31 of 34 files differ. Not reformatted on
   purpose: it would bury real changes in churn. Clear per-file when next editing one.
5. **Four prefab-embedded scripts** in `ServerStorage.Assets` remain Studio-owned
   (two `RainbowCycle`, two `PurchaseHandler`, each pair byte-identical).
6. `TestService.RobloxLSP_Settings` is editor junk still in the place.

The full debt table lives in `ARCHITECTURE.md`.

### Notes worth keeping

- **Correction made mid-session:** type-checking caught a bug introduced two commits
  earlier — `snapshot.lock = isFinal and nil or {...}` always yields the table
  (`x and nil` is nil, which is falsy), so the session lock was refreshed rather than
  released on logout. That would have locked players out of their own profile for the
  full 240s staleness window. Fixed, and commit `ac99840`'s message was amended to
  disclose it rather than leave the history misleading.
- A stale `rojo serve` for the unrelated **Hooked** project was holding the default
  port 34872. Connecting Studio normally would have synced Hooked's tree into Toilet
  Farm. Killed with the user's approval. Check `projectName` before connecting.
- Team Create is on but `violentlean` is the user's own account — sole editor, no
  collaborator conflict.
- The Rojo Studio plugin was not installed; added via `rojo plugin install`.
