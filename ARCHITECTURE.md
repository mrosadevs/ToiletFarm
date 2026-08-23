# Toilet Farm — Architecture

What this game **is right now**, including the parts that are not good yet.
For rules that apply to every change, see `CLAUDE.md`.
For how it got here session by session, see `HISTORY.md`.

## Migration status

Migrated from a Studio-authored place to Rojo on **2026-08-20**.

- Pre-migration backup: `~/Documents/ToiletFarm_Backups/ToiletFarm_pre-migration_2026-08-20.rbxl`
  (sha1 `f83f73a0374281c987544b6d243fe7edd14fe6ad`)
- Place: `ToiletFarm`, placeId `130638230805196`, gameId `10715957263`
- Migration commit `43b69d2` is pure movement: all 31 scripts byte-identical,
  verified by rebuilding the tree and diffing every source against the original place.

**Rojo owns** (filesystem is authoritative — never edit these in Studio):

| DataModel path | Source |
|---|---|
| `ReplicatedStorage.Shared` | `src/shared` |
| `ServerScriptService` | `src/server` |
| `StarterPlayer.StarterPlayerScripts` | `src/client` |

All three are mapped with `$ignoreUnknownInstances: false`, so Rojo owns those
containers completely and deletions propagate.

**Studio owns** (do not try to move these into the filesystem):

Terrain · `Workspace.Plots` (6 plot models) · `Workspace.Hub` (59 scenery models) ·
`StarterGui` (13 authored `ScreenGui`s) · `ServerStorage.Assets` (toilet, poop,
mutation, lucky-block and prop prefabs) · Lighting · `MaterialService` variants ·
`ReplicatedStorage.Remotes` (an empty folder that `Shared.Net` fills at runtime)

## Domains

**Server** — `src/server`, one entry point plus twelve service modules.

`Main.server.luau` boots services in dependency order and owns every remote handler.

| Module | Owns |
|---|---|
| `Services/DataService` | The player profile. Load, autosave, session lock, and the single push path to the client. Everything else reads through `get()` and replicates through `push()`. |
| `Services/EconomyService` | Deposits, the selling queue, banked cash, upgrades, rebirth, offline earnings, the free-money chest. |
| `Services/PassService` | Gamepass and dev-product ownership, live prices, `ProcessReceipt`. |
| `Services/PlotService` | Plot claiming, rebuilding, stalls, teleporting home. |
| `Services/ToiletService` | Toilet placement, merging, drop timers. |
| `Services/PoopService` | Physical poop bodies, pickup, carrying. |
| `Services/LuckyBlockService` | Lucky block grants, opening, mutations. |
| `Services/FlushMeterService` | The server-wide 30s deposit multiplier. |
| `Services/IndexService` | Toilet discovery index. |
| `Services/TutorialService` | Step tracking and prompts. |
| `Services/PadService` | Walk-on pads: buy, upgrade, process, finish-now, pass prompts. |
| `Services/CodesService` | Redeemable codes. |
| `Services/AnalyticsService` | Every event the game reports to the Creator Dashboard: the tutorial as an onboarding funnel, session-playtime and rebirth-run funnels, the rebirth progression path, and the cash/token/Robux economy flows. |
| `Services/EventPromptService` | The Roblox event RSVP dialog: who gets asked, when, and the once-per-event record that stops it coming back. |
| `Security/RemoteGuard` | The single door for every client-to-server call: rate limit, argument validation, dispatch. |
| `Security/RateLimiter` | Per-player, per-action token buckets. |

**Client** — `src/client`, `ClientMain.client.luau` plus twelve controllers in
`Controllers/`. The controllers **bind to the Studio-authored `StarterGui`
hierarchy**; they do not build it. `State` holds replicated profile state, `Screens`
routes panels, `UIKit` provides interaction helpers, `Hud` / `Panels` / `Index` /
`Lucky` / `Popups` / `Tutorial` drive individual screens, `WorldFx` and `Audio`
handle feedback.

`Freecam` is the exception to "do not build UI in code": it is a capture tool, not
part of the game's view, so it owns the small overlay it draws. Shift+F detaches the
camera, freezes the character and hides the HUD for filming; it touches no server
state and cannot, so it ships enabled for everyone (`ALLOW` at the top of the file
takes UserIds if that ever needs narrowing). It deliberately avoids Shift+P, which
is Studio's own injected freecam — that one exists only in playtests, never in a
published client.

**Shared** — `src/shared`: `ToiletConfig` (the content and tuning tables, 497 lines
and the single source of game balance), `Net` (remote definitions and canonical
names), `Prices` (the Robux dashboard cross-check), `Format`, `IconManifest`, `SoundIds`.

## Trust boundaries

**Server-authoritative.** Cash, poops, toilets, upgrades, perks, rebirth, tokens,
discovery, lucky blocks, offline earnings, and the chest cooldown are all computed
and stored server-side. The client never sends a value the server should own.

Most economy actions are not reachable by remote at all — buying, depositing,
collecting and processing happen through server-side pads driven by `Touched`, so
there is no endpoint to forge. The client-to-server surface is only:

`Merge` · `Rebirth` · `BuyUpgrade` · `BuyTokenPerk` · `OpenLucky` · `DiscardLucky` ·
`RedeemCode` · `SetSetting` · `TeleportHome` · `ClaimOffline` · `RequestState`

Every one goes through `RemoteGuard` with a per-action rate limit and argument
validation. The x2 offline claim is granted only by a dev-product receipt, never by
a client flag — `ClaimOffline`'s `doubled` argument is accepted for wire
compatibility and deliberately ignored.

**Known client-authoritative gaps.** None found in the economy. The remaining
client trust is cosmetic: the client picks its own VFX and audio timing.

## Persistence

`DataService` is the only module that touches `DataStoreService`. Store
`ToiletFarm_v1`, key `p_<UserId>`, autosave every 90s, final save on
`PlayerRemoving` and `BindToClose`.

- Reads and writes both go through `UpdateAsync`, so they are atomic against
  other servers.
- **Session locking**: the profile records the owning `JobId` and a heartbeat.
  Another server may only take it after 240s without a refresh. An orderly
  shutdown releases the lock in the final save.
- Snapshots are **deep** copies, so a mutation during the yielding write cannot
  produce a torn save.
- Failed saves retry with backoff, and `save()` returns whether the data is
  durably stored.
- `ProcessReceipt` is **idempotent**: grants are recorded in `profile.receipts`
  by `PurchaseId`, and `PurchaseGranted` is only returned once that ledger entry
  is confirmed saved.
- A failed *load* kicks the player rather than handing out a fresh profile,
  because a fresh profile would overwrite real progress on the next autosave.

## Analytics

`AnalyticsService` is the only module that calls Roblox's `AnalyticsService`, and
everything it reports is raised from the server path that already decided the
thing happened. There is no remote and no client entry point: a client that could
post its own funnel steps could invent an audience.

Nothing it does may affect gameplay. Every call is wrapped, and a failure warns
once per event and is then swallowed for the life of the server — a reporting
outage must not stop somebody buying a toilet, and a broken event must not write a
log line on every fire.

| What | How it is reported | Reads as |
|---|---|---|
| Tutorial | Onboarding funnel, step 1 `Joined` then one per `TutorialService.STEPS` entry | Which tutorial step first-time players quit on |
| Playtime | `Session` funnel, steps at 1/5/10/20/30/60 minutes, plus a `SessionEnd` custom event carrying the exact minutes | Where inside a sitting people leave |
| Rebirth grind | `RebirthRun` funnel: run start, 25%, 50%, 75%, affordable, rebirthed | How far up the cost of the next rebirth a sitting gets. **`Affordable` → `Rebirthed` is the row to watch**: a drop there is not pacing, it is somebody who had the cash and did not press the button |
| Rebirth ladder | Progression path `Rebirth`, one level per rebirth, Start and Complete | Per-level completion rate over a player's lifetime |
| Cash, tokens, Robux | Economy source/sink events, one `sku` per thing bought or reason paid | Where money comes from and goes |

Three things about it are load-bearing:

- **Scope is chosen per event, and the two scopes are different.** The onboarding
  funnel and the progression Start are *lifetime* events, so their high-water marks
  are persisted in `profile.analytics` — held in memory they would re-report on
  every server the player touched. The `Session` and `RebirthRun` funnels are
  per-sitting, and their session ids are regenerated on join, which is what makes
  them answer the drop-off question at all.
- **Custom fields are buckets, never raw values.** Roblox gives an event exactly
  three, and each wants a small set of distinct values because they are dashboard
  breakdowns. Fields 1 and 2 are the same on every event — rebirth bucket and total
  playtime bucket — so any funnel can be read per progression stage and per cohort
  age. Field 3 is the event's own detail and defaults to whether the player has
  ever paid. A cash amount in a custom field would make the breakdown useless.
- **The two high-frequency cash paths are pooled.** Auto Collect Cash lands in
  `collectCash` every two seconds, and the bulk Buy pad calls `ToiletService.buy`
  up to forty-one times for one press. Both accumulate per sku and flush once per
  five-second tick, which reports identical totals against the same balance
  without putting forty rows on the dashboard for one button press.

Old profiles are seeded rather than left at zero: a save written before this
existed carries `analytics.onboard = 0` even if the player finished the tutorial
months ago, so the mark is back-filled from `profile.tutorial` on join and
veterans never enter the top of a first-timers' funnel.

## The Roblox event prompt

`EventPromptService` raises Roblox's own RSVP dialog four minutes into a session.
Roblox hosts the dialog, so there is no UI here and nothing to style. The dialog is
a **client-only** API, which is the only reason a remote is involved: the server
decides who is asked and when, and `ClientMain` does nothing but raise it — the
same shape the group-join pad already uses.

- **Once means once, and it is persisted.** `profile.eventPrompt` records the event
  id a player has already been shown, so the dialog cannot come back on a rejoin,
  a server hop or the next session. It holds the *id* rather than a boolean so
  announcing a new event asks once more, instead of one flag silencing every event
  this game will ever run.
- **The mark is written before the dialog is raised, and regardless of the answer.**
  Showing it once is a promise about the dialog appearing, not about getting a yes;
  a prompt that retried until somebody accepted would be the nagging this avoids.
- The four minutes are measured from the join, not from when the profile finished
  loading, so a slow load does not push the dialog later and later.
- The client skips the prompt for anyone whose RSVP status is already not `None` —
  they said yes on the game page, so there is nothing left to ask.

The event id lives at the top of the service. It is not balance, so it is not in
`ToiletConfig`.

## Known debt

Carried forward from the migration audit. These are real and unfixed; do not
opportunistically "fix" them mid-task — each gets its own change.

| Item | Tier | Where | Notes |
|---|---|---|---|
| `AutoMerge` and `ExtendedSeptic` gamepasses have id `0` | 2 | `Services/PassService` | Declared but not created on the site. Until real ids are entered, auto-merge never runs, the AutoMerge pad says "Coming soon!", and every player gets the short offline cap. **This needs a dashboard action, not a code change.** |
| Rebirth "SkipButton" is a stub | 3 | `client/Controllers/Panels` | Toasts "Instant Rebirth coming soon!" while an `InstantRebirth` product handler already exists in `Main`. |
| Four scripts live inside `ServerStorage` prefabs | 3 | `ServerStorage.Assets.**` | Two `RainbowCycle` copies and two `PurchaseHandler` copies, each pair byte-identical. Not Rojo-managed. The right shape is tags + one component module (standard §21), but they work and are not on a hot path. |
| No types at the persistence boundary | 3 | `Services/DataService` | The profile is `any` throughout. A `PlayerProfile` type would catch schema drift at the seams. |
| Pre-existing luau-lsp diagnostics | 3 | `shared/ToiletConfig`, `client/Controllers/{UIKit,Lucky,Index,Popups,Tutorial}` | ~20 nil-safety and unused-import warnings in files untouched by the migration. Fix per-file when next editing them, with `--!strict`. |
| `TestService.RobloxLSP_Settings` | cosmetic | the place | Editor plugin artifact left in the DataModel. |
| No automated tests | 3 | — | The deterministic high-risk logic (`ToiletConfig` cost curves, offline maths, `RateLimiter`) is testable and untested. |
| Tree is not StyLua-formatted | 3 | `src/` | 31 of 34 files differ from `stylua.toml`. The config was tuned to match the existing hand-formatting as closely as it can (`ConditionalOnly`), but a tree-wide `stylua src/` would still be a large diff. Format per-file when next editing one; `src/server/Security` is already clean. |
| No CI | 3 | — | `selene`, `stylua --check` and `rojo build` all run clean enough to gate on, but nothing runs them automatically. |

## Verification performed at migration

```text
[x] Pre-migration backup exists, verified by checksum, stored outside the repo
[x] Audit delivered before extraction
[x] Rojo/Studio ownership split agreed
[x] 31/31 scripts extracted byte-identical (0 missing, 0 extra, 0 differing)
[x] default.project.json reproduces the pre-migration hierarchy exactly
[x] No duplicate execution: every mapped container's script count matches its $path
[x] rojo build succeeds
[x] Rojo sync verified live, including deletion propagation
[x] RateLimiter and RemoteGuard validators exercised in Studio
[ ] Core loop playtested end to end          <- owner: you
[ ] Persistent data verified across two rejoins  <- owner: you
```

The two unchecked boxes need a human at the controls. See `CLAUDE.md` for what to
watch during that pass.
