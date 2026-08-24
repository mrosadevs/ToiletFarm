# 🚽 Toilet Farm

> A Roblox tycoon — buy toilets, they drop poop, haul it to the septic tank, sell it, upgrade, rebirth. Filesystem-first with Rojo, VS Code, and Git.

[![Made by mrosadevs](https://img.shields.io/badge/Made%20by-mrosadevs-00e5a0?style=flat-square)](https://github.com/mrosadevs)
[![Luau](https://img.shields.io/badge/Luau-Roblox-00a2ff?style=flat-square&logo=roblox)](https://luau-lang.org/)
[![Rojo](https://img.shields.io/badge/Rojo-7.7.0-ff5f5f?style=flat-square)](https://rojo.space/)
[![Services](https://img.shields.io/badge/Services-12-7c5cfc?style=flat-square)](#-architecture)
[![Server Authoritative](https://img.shields.io/badge/Economy-Server%20Authoritative-ffd740?style=flat-square)](#-trust-boundaries)

---

## 💩 Core Loop

Buy a toilet. Wait for the drop. Carry it. Deposit it. Get paid. Buy a better toilet.

- 🚽 **Toilets** — place them on your plot, merge duplicates into higher tiers
- 💩 **Poop** — physical bodies you actually pick up and carry
- 🏦 **Septic tank + selling queue** — deposit, process, bank the cash
- 📈 **Upgrades & rebirth** — reset for permanent multipliers and token perks
- 🍀 **Lucky blocks & mutations** — server-rolled grants, never client-decided
- 🌊 **Flush meter** — a server-wide 30-second deposit multiplier everyone shares
- 📖 **Discovery index** — completionist tracking for every toilet
- 🎁 **Codes, offline earnings, and a free-money chest**
- 🎓 **Tutorial** — step tracking and prompts for new players

## 🧩 Architecture

One server entry point, twelve services, eleven client controllers, and a shared config layer. `Main.server.luau` boots services in dependency order and owns every remote handler.

| Service | Owns |
|---|---|
| **DataService** | The player profile — load, autosave, session lock, and the single push path to the client |
| **EconomyService** | Deposits, selling queue, banked cash, upgrades, rebirth, offline earnings |
| **PassService** | Gamepass and dev-product ownership, live prices, `ProcessReceipt` |
| **PlotService** | Plot claiming, rebuilding, stalls, teleport home |
| **ToiletService** | Placement, merging, drop timers |
| **PoopService** | Physical bodies, pickup, carrying |
| **LuckyBlockService** | Grants, opening, mutations |
| **FlushMeterService** | The server-wide deposit multiplier |
| **IndexService / TutorialService / PadService / CodesService** | Discovery, onboarding, walk-on pads, redeemables |
| **Security/RemoteGuard** | The single door for every client-to-server call |

The client **binds to** the Studio-authored `StarterGui` hierarchy — it does not build UI in code. `State` holds replicated profile state, `Screens` routes panels, and `Hud` / `Panels` / `Index` / `Lucky` / `Popups` / `Tutorial` drive individual screens.

`ToiletConfig.luau` is the single source of game balance — all content and tuning tables live there, not in code.

## 🔒 Trust Boundaries

Cash, poops, toilets, upgrades, perks, rebirth, tokens, discovery, lucky blocks, offline earnings, and the chest cooldown are **all computed and stored server-side**.

Most economy actions aren't reachable by remote at all — buying, depositing, collecting, and processing run through server-side pads driven by `Touched`, so there's no endpoint to forge. The entire client-to-server surface is eleven actions:

```
Merge · Rebirth · BuyUpgrade · BuyTokenPerk · OpenLucky · DiscardLucky
RedeemCode · SetSetting · TeleportHome · ClaimOffline · RequestState
```

Every one passes through `RemoteGuard` with a per-action token-bucket rate limit and argument validation. The x2 offline claim is granted only by a dev-product receipt — `ClaimOffline`'s `doubled` argument is accepted for wire compatibility and **deliberately ignored**.

## 💾 Persistence

`DataService` is the only module that touches `DataStoreService`.

- Store `ToiletFarm_v1`, key `p_<UserId>`, autosave every 90s, final save on `PlayerRemoving` and `BindToClose`
- Reads and writes both go through `UpdateAsync` — atomic against other servers
- **Session locking** via owning `JobId` + heartbeat; another server may only take over after 240s without a refresh
- Snapshots are **deep** copies, so a mutation mid-write can't produce a torn save
- `ProcessReceipt` is **idempotent** — grants are ledgered by `PurchaseId` and `PurchaseGranted` only returns once that entry is durably saved
- A failed *load* kicks the player rather than handing out a fresh profile that would overwrite real progress

## 🛠️ Tech Stack

- **Luau** — services + controllers, no framework
- **Rojo 7.7.0** — filesystem ↔ Studio sync
- **Rokit** — pins rojo, stylua, selene, luau-lsp, lune
- **StyLua + Selene** — formatting and linting
- **Studio MCP** — DataModel, UI, and playtest inspection only

## 🚀 Setup

```bash
git clone https://github.com/mrosadevs/ToiletFarm.git
cd ToiletFarm
rokit install
rojo serve default.project.json
```

Then in Studio: **Plugins → Rojo → Connect**.

Generate the sourcemap so `luau-lsp` resolves requires:

```bash
rojo sourcemap default.project.json -o sourcemap.json --watch
```

## ✅ Checks

```bash
rojo build default.project.json -o /tmp/build.rbxl
stylua --check src/
selene src/
```

## 📁 Project Structure

```
ToiletFarm/
├── 📁 src/
│   ├── 📁 server/              # → ServerScriptService
│   │   ├── 📄 Main.server.luau # boots services, owns every remote handler
│   │   ├── 📁 Services/        # 12 gameplay services
│   │   └── 📁 Security/        # RemoteGuard + RateLimiter
│   ├── 📁 client/              # → StarterPlayerScripts
│   │   └── 📁 Controllers/     # 11 controllers, bound to Studio-authored GUIs
│   └── 📁 shared/              # → ReplicatedStorage.Shared
│       └── 📄 ToiletConfig.luau # 497 lines — the single source of balance
├── 📄 default.project.json     # Rojo mapping
└── 📄 CLAUDE.md                # always-on rules for AI-assisted work
```

## ⚠️ Before You Edit

Read **`CLAUDE.md`** (always-on rules) before picking up unfinished work.

Migrated from Studio on **2026-08-20**. The migration commit is pure movement — all 31 scripts byte-identical, verified by rebuilding the tree and diffing every source against the original place.

**Do not edit script source in Studio.** Rojo owns `ReplicatedStorage.Shared`, `ServerScriptService`, and `StarterPlayerScripts` with `$ignoreUnknownInstances: false` — it owns those containers completely and deletions propagate. Everything else (Terrain, `Workspace.Plots`, `Workspace.Hub`, `StarterGui`, `ServerStorage.Assets`, Lighting) is Studio-authored and stays there.

---

<p align="center">Made with 👻 by <a href="https://github.com/mrosadevs">mrosadevs</a> · Built with Rojo, not vibes</p>
