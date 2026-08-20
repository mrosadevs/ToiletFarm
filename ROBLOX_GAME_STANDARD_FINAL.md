# ROBLOX GAME PRODUCTION STANDARD

> The engineering constitution for serious Roblox games built with Claude Code, VS Code, Git, Rojo, Roblox Studio, and Roblox Studio MCP.

---

## How to Use This Document

This is a **reference manual**, not a context payload. Do not paste it into every session.

| File | Role | Size |
|---|---|---|
| `CLAUDE.md` | Always-on rules. Loaded every session. | ~150 lines |
| `.claude/rules/*.md` | Path-scoped rules. Loaded when touching matching files. | ~50 lines each |
| `ARCHITECTURE.md` | What **this specific game** actually is. | Grows with the game |
| `ROBLOX_GAME_STANDARD_FINAL.md` | This file. Consulted for architectural decisions. | Reference |

Read the relevant *section* of this document when making an architectural decision. Read the whole thing when bootstrapping a project or auditing one.

**Everything here is a principle with a recommended default.** Folder trees, module names, and domain lists are **examples**. They are not a mandate to reorganize an existing coherent project. When this document and a working codebase disagree about naming or layout, the codebase wins unless there is a demonstrated structural problem.

---

# PART I — PHILOSOPHY

---

## 1. Purpose

This standard exists for games that may eventually reach:

hundreds or thousands of ModuleScripts · large concurrent populations · large streamed maps · complex UI systems · Figma-authored interfaces · large asset libraries · persistent inventories and economies · trading · monetization · quests · progression · live events · seasons · NPC systems · vehicles · combat · VFX · audio · animation · analytics · anti-exploit systems · multiple developers · years of live development.

**But it must never be read as permission to build all of that now.**

> ### Build for scale without pretending scale already exists.

Scale readiness is about **structure**, not **volume**. A project is scale-ready when a new system has an obvious home, a clear owner, and a defined trust boundary — not when it has forty layers of indirection waiting for traffic that has not arrived.

The goal is not maximum architecture. The goal is:

> ### The least complexity required for a professional, secure, maintainable, scalable production solution.

Every system should let a developer answer, without archaeology:

```text
Where does this live?
Who owns it?
Who is allowed to mutate it?
How does it communicate?
What is authoritative?
How is it cleaned up?
How does it behave under load?
```

## 2. The Complexity Contract

Three sentences govern every decision in this document:

1. **Professional does not mean complicated.**
2. **Scalable does not mean overengineered.**
3. **Simple does not mean primitive.**

"Simple" does not mean one giant script, globals, no types, no validation, client authority, or hardcoded content. It means *the least machinery that solves the real problem robustly*.

When two designs are both correct and both safe, choose the one with fewer moving pieces, fewer files, fewer dependencies, less hidden behavior, and clearer ownership.

## 3. Conflict Resolution Priority

When rules, sources, or instincts conflict, resolve in this order:

```text
1. Security and correctness
2. Current official platform behavior
3. Compatibility with the existing project
4. Simplicity
5. Maintainability
6. Clear ownership
7. Performance supported by evidence
8. Scalability based on realistic need
9. Personal stylistic preference
```

Security and correctness are never traded for brevity. Personal style never outranks an existing working convention in the repository.

## 4. Universal vs Project-Specific

This document defines **universal engineering rules**. It does not define **your game**.

Examples in this document use Fishing, Combat, Inventory, Shop, and Trading because concrete examples teach better than abstract ones. **They are examples.** A game with no trading must not contain a Trading domain. A game with no NPCs must not contain an NPC registry.

Your game's actual domains, layers, contracts, and budgets belong in `ARCHITECTURE.md`, written as the game is built, not copied from here.

---

# PART II — FOUNDATIONS

---

## 5. Toolchain

The default stack for every serious project:

```text
Claude Code      agent
VS Code          editor
Git              history
Rokit            toolchain version pinning
Rojo             filesystem → DataModel sync
Wally            Luau package dependencies (only when a real dependency exists)
StyLua           formatting
Selene           linting
luau-lsp         types, sourcemap-aware completion
Roblox Studio    the engine, playtesting, visual authoring
Studio MCP       Claude's window into the live DataModel
```

**Do not adopt a framework that owns the architecture** — no Knit, no AeroGameFramework, no dependency-injection container — unless explicitly requested and justified. Custom ModuleScript architecture with an explicit bootstrap is the default.

Small, focused libraries that solve a real problem are fine. A framework that decides how your entire game is structured is not.

Pin tool versions with Rokit (`rokit.toml`) so every developer and CI runner uses identical binaries. Rokit supersedes Foreman and Aftman; both have uncertain maintenance futures, and Rokit reads their manifests during migration.

### Primary flow

```text
Claude Code
    ↓
Filesystem (src/**/*.luau)
    ↓
Rojo
    ↓
Roblox Studio
```

Git tracks the filesystem. Studio renders it.

## 6. The Filesystem Is the Source of Truth

**For anything Rojo manages, the local filesystem is authoritative.**

Correct:

```text
Claude edits  src/server/domains/Fishing/FishingService.luau
    ↓ rojo serve
Studio updates the ModuleScript
```

Wrong:

```text
Claude edits ModuleScript.Source through Studio MCP
    ↓
Rojo overwrites it on next sync — or worse, doesn't, and now two versions exist
```

**Never edit Rojo-managed script source through Studio MCP.** That creates a second source of truth, and the loser is silently discarded.

Studio MCP is for work that *requires* Studio: hierarchy inspection, UI inspection, Figma import review, model and property work, tags, attributes, map objects, Lighting, VFX authoring, runtime state, playtests, and debugging. See §38.

### What Rojo should and should not own

| Owned by Rojo (filesystem) | Owned by Studio (`.rbxm`/`.rbxmx` committed as binary, or authored live) |
|---|---|
| All `.luau` source | Terrain |
| Project structure and container mapping | Large authored map geometry |
| `.model.json` for simple structural instances | Figma-imported UI hierarchies |
| Small committed prefabs as `.rbxmx` | Complex particle/VFX assemblies |
| Configuration and registries | Lighting and post-processing setups |

Anything Studio-authored that must be versioned should be exported to `assets/` as a model file and referenced by a `$path` in the project file. Binary `.rbxm` does not diff well; prefer `.rbxmx` (XML) for anything you want to review in a PR, and accept `.rbxm` for large opaque assets.

## 7. Repository Architecture

A recommended shape. Adapt it; do not instantiate empty folders from it.

```text
Game/
├── src/
│   ├── bootstrap/
│   │   ├── ServerBootstrap.server.luau
│   │   ├── ClientBootstrap.client.luau
│   │   └── LoadingBootstrap.client.luau
│   │
│   ├── server/
│   │   ├── domains/          ← Player, Economy, Inventory, World, ...
│   │   ├── security/         ← RemoteGuard, RateLimiter, validators
│   │   ├── persistence/      ← data layer, schemas, migrations
│   │   ├── analytics/
│   │   └── liveops/
│   │
│   ├── client/
│   │   ├── controllers/
│   │   ├── ui/               ← router, layers, components, theme
│   │   ├── input/
│   │   ├── camera/
│   │   ├── vfx/
│   │   ├── audio/
│   │   └── state/
│   │
│   └── shared/
│       ├── types/
│       ├── config/
│       ├── constants/
│       ├── network/          ← remote contracts, typed wrappers
│       ├── registries/       ← content definitions
│       ├── state/
│       └── util/
│
├── assets/
│   ├── replicated/           ← UI, VFX, ViewModels, SharedModels, Animations
│   └── server/               ← Maps, NPCs, Loot, Templates
│
├── tests/
├── tools/
├── docs/
│   ├── UI_ARCHITECTURE.md
│   └── ASSET_MANIFEST.md
├── .claude/rules/
├── .github/workflows/
├── default.project.json
├── rokit.toml
├── wally.toml
├── .luaurc
├── stylua.toml
├── selene.toml
├── CLAUDE.md
├── ARCHITECTURE.md
└── README.md
```

Two organizing axes exist, and both are defensible:

- **By layer** (`server/`, `client/`, `shared/`, then domains inside) — the default here. It makes trust boundaries visible in the path, which matters more than colocation for a security-sensitive platform.
- **By feature** (`Fishing/{server,client,shared}`) — better colocation, weaker boundary visibility.

Pick one per project and hold it. A repository that mixes both is worse than either.

### Rojo project file

`default.project.json` maps the tree into the DataModel. Keep it readable and keep it the single description of that mapping.

```json
{
  "name": "MyGame",
  "tree": {
    "$className": "DataModel",
    "ReplicatedStorage": {
      "Shared":  { "$path": "src/shared" },
      "Client":  { "$path": "src/client" },
      "Assets":  { "$path": "assets/replicated" }
    },
    "ServerScriptService": {
      "ServerBootstrap": { "$path": "src/bootstrap/ServerBootstrap.server.luau" },
      "Server":          { "$path": "src/server" }
    },
    "ServerStorage": {
      "Assets": { "$path": "assets/server" }
    },
    "StarterPlayer": {
      "StarterPlayerScripts": {
        "ClientBootstrap": { "$path": "src/bootstrap/ClientBootstrap.client.luau" }
      }
    },
    "Workspace": {
      "$properties": { "StreamingEnabled": true }
    }
  }
}
```

Generate `sourcemap.json` (`rojo sourcemap default.project.json -o sourcemap.json`) so luau-lsp resolves `require` paths. Regenerate it in a watch task and in CI; do not hand-maintain it.

Use separate project files when justified — `dev.project.json` for a place with debug tooling attached, `default.project.json` for production — but never let them drift into two different architectures.

## 8. ModuleScripts and Bootstraps

The overwhelming majority of code is ModuleScripts. There should be a **small, countable number of executable entry points**:

```text
ServerBootstrap.server.luau
ClientBootstrap.client.luau
LoadingBootstrap.client.luau   (ReplicatedFirst, only if there is a loading screen)
```

Do not put a `LocalScript` in every UI button. Do not put a `Script` in every door, collectible, NPC, or map object. Behavior comes from modules, components, tags, registries, and centralized systems.

### Deterministic startup

Use two phases when a project is large enough to have ordering concerns:

```luau
-- Init: build state, register handlers, validate dependencies. No gameplay yet.
-- Start: begin loops, accept players, activate systems that assume Init completed.
```

```luau
-- ServerBootstrap.server.luau
local DOMAINS = {
    require(Server.Player),
    require(Server.Persistence),
    require(Server.Economy),
    require(Server.Inventory),
    require(Server.World),
}

for _, domain in DOMAINS do
    if domain.Init then domain.Init() end
end

for _, domain in DOMAINS do
    if domain.Start then domain.Start() end
end
```

The ordered list *is* the dependency declaration. That is usually enough. Do not build a topological-sort dependency resolver until manual ordering has actually become unmanageable.

**Never solve an ordering problem with `task.wait(3)`.** If something is not ready, express readiness explicitly — a signal, a state flag, a promise, an `Init`/`Start` split — so the failure mode is a clear error rather than an intermittent race.

## 9. Roblox DataModel Organization

Containers are chosen by **replication, ownership, security, lifecycle, and loading behavior** — never by convenience.

```text
ReplicatedFirst
└── LoadingBootstrap + minimal loading assets

ReplicatedStorage
├── Shared           shared modules, types, config, registries
├── Client           client modules (mapped here so the client can require them)
├── Network          remote objects / typed network layer
└── Assets
    ├── UI           templates and components the client clones
    ├── VFX
    ├── ViewModels
    ├── SharedModels
    └── Animations

ServerScriptService
├── ServerBootstrap
└── Server           all server domains

ServerStorage
└── Assets
    ├── Maps
    ├── NPCs
    ├── Loot
    └── Templates

StarterPlayer/StarterPlayerScripts
└── ClientBootstrap

StarterGui
└── AppRoot          root ScreenGui / UI layer host

Workspace
├── World            authored environment
└── Runtime          instances created at runtime

SoundService, Lighting
└── configured environment
```

### Container rules

**ReplicatedStorage** — everything here is downloaded by and visible to every client. Assume an exploiter reads all of it. It holds what the client legitimately needs: shared modules, client modules, network objects, UI/VFX templates, client-visible models, shared config, shared types, non-sensitive registries.

Never place there: server secrets, authoritative security logic, unreleased content, admin lists, drop-rate tables you consider sensitive, or server-only economic authority. "The client can't see this ModuleScript" is not a security property — it is a false belief.

**ServerStorage** — templates and content the client does not need until the server intentionally uses them: map templates, NPC templates, loot templates, server-only models. Do not replicate every possible map to every client at join.

**ServerScriptService** — server code. Never use ServerStorage as a code dumping ground.

**Workspace** — the live 3D world, not a warehouse.

```text
Workspace
├── World
│   ├── Regions       Downtown, Harbor, Suburbs, ...
│   ├── Gameplay      SpawnPoints, Interactions, Zones, QuestLocations
│   ├── Navigation    Paths, Nodes
│   └── Environment   Foliage, Props, Structures
└── Runtime
    ├── NPCs
    ├── Vehicles
    ├── Projectiles
    ├── Drops
    └── Temporary
```

`World` is authored. `Runtime` is created by the running server. Nothing dormant lives in Workspace.

**ReplicatedFirst** — only what the first frame needs. It blocks. Do not preload the catalog here.

## 10. Asset Placement Decision

Before adding any asset, answer:

```text
Does the client need to render or reference it?      → ReplicatedStorage/Assets
Is it server-only content or a spawn template?       → ServerStorage/Assets
Is it currently live in the world?                   → Workspace
Is it a reusable authored unit across places/games?  → Roblox Package
Does an identical asset already exist?               → reuse it
```

Reuse mesh IDs, textures, modular building pieces, trim sheets, and materials. Importing the same geometry as two hundred unique assets costs memory, load time, and consistency for nothing.

Use **Roblox Packages** for genuinely reusable authored units — a street lamp, a shop building, a vehicle spawner, a UI component pack. Do not package every trivial Part.

### Template vs runtime naming

Make the distinction unmissable:

```text
ServerStorage/Assets/NPCs/PoliceOfficerTemplate    ← source
Workspace/Runtime/NPCs/PoliceOfficer_381           ← live instance
```

### Asset manifest

Large projects maintain `docs/ASSET_MANIFEST.md` or a machine-readable registry recording, for important assets: canonical name, Roblox asset ID, type, owning domain, source, purpose, and replacement notes. This exists to prevent four mystery copies of the same texture with four different IDs.

**Never scatter raw asset IDs through code.**

```luau
-- Bad, repeated in 30 modules
sound.SoundId = "rbxassetid://123456789"

-- Good
sound.SoundId = Assets.Audio.UI.Click
```

---

# PART III — CODE ARCHITECTURE

---

## 11. Domains and Ownership

Organize the game into explicit domains. Each domain owns its state and behavior and exposes a deliberate public API.

Typical domains (again: examples, not a checklist):

```text
Player  Inventory  Economy  Progression  Combat  World  NPC
Social  Trading  Quests  Monetization  Security  Analytics  LiveOps
```

**One responsibility has exactly one owner.** If two modules can both mutate player currency, you do not have an economy — you have a race condition with a marketing name.

```text
Good:                            Bad:
ShopController                   ShopButton LocalScript
  → PurchaseItem remote            → fires a remote
  → EconomyService                 → server writes profile.Coins directly
    → PlayerDataService            → InventoryService writes profile.Coins elsewhere
```

A large domain gets internal structure, and only its facade is public:

```text
server/domains/Fishing/
├── init.luau              public API — the only thing other domains require
├── CatchValidator.luau
├── CatchResolver.luau
├── FishingSession.luau
└── internal/
    ├── WeightRoller.luau
    ├── RarityRoller.luau
    └── CatchMath.luau

shared/Fishing/
├── FishingTypes.luau
├── FishingConfig.luau
└── FishRegistry.luau

client/Fishing/
├── FishingController.luau
├── CastingController.luau
└── FishingEffectsController.luau
```

Nothing outside `Fishing/` requires anything in `Fishing/internal/`. That convention is enforced by review and by lint rules, not by the language — so name the folder `internal/` and mean it.

## 12. Dependency Rules

```text
        Shared
        ↑    ↑
   Server    Client
```

- Shared must not require server-only or client-only code.
- Client must not require server source.
- Server must not require client source.
- No circular requires. If two modules need each other, extract the shared concept or move the dependency into shared types.

Domains communicate through public APIs, signals, or network contracts — never by reaching into another domain's tables.

**Prefer direct calls over event buses.** `InventoryService.AddItem(player, itemId)` is clearer, debuggable, and type-checkable. Use signals for genuine one-to-many notification (state changed, player left, round ended), not to avoid writing an import.

## 13. Naming

```text
Folders / Instances / ModuleScripts / Types / public APIs   PascalCase
local variables and functions                               camelCase
constants                                                   UPPER_SNAKE_CASE
```

### Module suffixes

```text
*Service      server-owned domain facade or singleton
*Controller   client-side coordinator
*System       contained process or subsystem
*Component    behavior attached to tagged/runtime instances
*Config       static tunable values
*Registry     indexed content definitions
*Types        shared type definitions
*Validator    validation logic
*Adapter      boundary to an external API or system
```

Avoid `Manager` — it means "this module owns something I did not want to name." Name modules by what they own.

Banned as module names: `Script`, `Script2`, `Module`, `Handler`, `Thing`, `Stuff`, `Utils`, `Misc`, `NewModule`, `Test123`.

Booleans read as assertions: `isAlive`, `hasPass`, `canPurchase`, `shouldRespawn`.

### Stable IDs

Persistent and networked content uses stable semantic IDs, never display names:

```luau
ItemId  = "GoldenRod"
QuestId = "HarborIntro"
NPCId   = "HarborMerchant"
```

Display names change for localization, seasons, and marketing. IDs must not. A save file keyed on `"Golden Rod"` breaks the day someone adds a space.

## 14. Server / Client / Shared Responsibilities

| Client owns (presentation) | Server owns (truth) |
|---|---|
| UI and input | Rules and validation |
| Camera | Currency, inventory, XP, levels |
| Local animation, VFX, audio | Purchases, rewards, trades |
| Viewmodels | Damage and match outcome |
| Prediction and cosmetic feedback | Quest completion, loot, crafting |
| Local interpolation | Progression, unlocks, cooldowns that matter |

**Prediction is not authority.** A client may show the swing immediately; the server decides whether it hit.

Any hybrid or predicted system must be designed explicitly, with a documented reconciliation path, and written down in `ARCHITECTURE.md`.

## 15. Types

Use `--!strict` for production modules where practical.

**Type explicitly:**

```luau
export type ItemId = string

export type InventoryEntry = {
    ItemId: ItemId,
    Quantity: number,
    Locked: boolean?,
}

export type PurchaseRequest = {
    ItemId: ItemId,
    Quantity: number,
}

export type PurchaseResult =
    { Ok: true, NewBalance: number, Entry: InventoryEntry }
  | { Ok: false, Reason: "InsufficientFunds" | "InventoryFull" | "UnknownItem" }
```

Public APIs, network payloads, persistent schemas, registries, and important shared state carry explicit types. Result unions like the one above are worth the keystrokes: they make failure modes exhaustive and reviewable.

**Do not type explicitly:**

```luau
local playerCount = 0          -- good
local playerCount: number = 0  -- noise
```

Let inference handle obvious locals. Avoid `any` unless a boundary genuinely is untyped (raw remote input before validation is the honest case — and it should be narrowed immediately).

Avoid type puzzles: deeply nested generics, giant unions, type-level gymnastics, and broad casts. **If the type is harder to understand than the runtime behavior, the design is wrong.**

Never walk through unrelated modules adding annotations while fixing a bug. That is a separate task, and it destroys the diff.

## 16. Content, Config, and Registries

Content-heavy systems are data-driven **when that reduces repetition**. Adding a fish, item, weapon, pet, quest, shop entry, or cosmetic should mean adding data — not editing twelve `if/elseif` chains.

```luau
-- shared/registries/FishRegistry.luau
export type FishDefinition = {
    Id: string,
    DisplayNameKey: string,   -- localization key, not a literal
    Rarity: Rarity,
    BaseValue: number,
    WeightRange: { Min: number, Max: number },
    Zones: { ZoneId },
}

return {
    Bluegill = { Id = "Bluegill", DisplayNameKey = "fish.bluegill", Rarity = "Common",
                 BaseValue = 12, WeightRange = { Min = 0.2, Max = 1.4 }, Zones = { "Lake" } },
    -- ...
}
```

```luau
-- Bad
if item == "Sword" then ...
elseif item == "Axe" then ...
elseif item == "Bow" then ...
```

**But do not force genuinely unique behavior into a universal config format.** A boss with a scripted three-phase fight is code. A config schema with a `SpecialBehaviorType` field and a fifty-branch dispatcher is worse than fifty lines of honest code.

The test: *does the next instance of this thing differ only in data?* If yes, registry. If no, code.

### Attributes vs Config vs State

```text
Attributes   per-instance authored configuration on a specific Instance
             Door.DoorId = "PoliceArmory", Door.RequiredLevel = 10

Config/Registry   global static definitions shared by all instances of a kind

Runtime state     changing gameplay values, owned by a service, never stored
                  in the DataModel just because it is convenient
```

Attributes are not a database. If you are writing player inventory into attributes, stop.

---

# PART IV — BOUNDARIES

---

## 17. Networking

Networking is deliberate. Before adding any RemoteEvent or RemoteFunction, answer:

```text
Why must this cross the boundary at all?
Which direction?
What is the exact schema?
Who is authoritative for each field?
What validation is required?
What is a legitimate call frequency?
What happens if it is called 10,000 times per second?
Can the server derive this value instead of receiving it?
Does the client actually need a response?
```

If the server can derive it, the server derives it. Every value the client sends is a value the client can lie about.

### Organization

Remotes live in one place with typed wrappers, not scattered through Workspace:

```text
ReplicatedStorage/Network
├── C2S     PurchaseItem, EquipItem, StartFishing, RequestTrade, AcceptQuest
└── S2C     InventoryUpdated, CatchResolved, QuestUpdated, Notification
```

Prefer **RemoteEvent** for fire-and-forget intent. Use **RemoteFunction** only when the client genuinely must block on a server answer; a client-invoked RemoteFunction that yields forever will hang the caller, and a server-invoked RemoteFunction lets a malicious client hang the *server thread* — never invoke a RemoteFunction on a client from the server.

Use **UnreliableRemoteEvent** only for ephemeral, high-frequency, loss-tolerant data (cosmetic position hints, non-authoritative effect pings). Never for transactions or state that must arrive. Payloads are size-capped and unordered; design accordingly.

### Contracts

Every request has a written contract:

```text
PurchaseItem  (C2S, RemoteEvent)

Input:   { ItemId: string, Quantity: number }

Server validates:
  rate limit for this player and action
  ItemId exists in ShopRegistry
  Quantity is an integer in [1, ItemDefinition.MaxStack]
  shop is currently accessible to this player
  player state permits purchase (not in trade, not dead, etc.)
  player balance >= server-resolved price * Quantity
  inventory has capacity

Server performs:
  single atomic currency + inventory mutation

Server responds (S2C InventoryUpdated + PurchaseResult):
  authoritative new balance, authoritative inventory delta
```

The price appears nowhere in the input. That is the point.

### Payload discipline

Send intent and minimal authoritative deltas.

```text
Bad:     full 200-item inventory after every purchase
Better:  { ItemId = "GoldenRod", NewQuantity = 3, NewBalance = 880 }
```

Do not replicate full state every frame. Do not send whole tables when an ID and a number suffice. Batch high-frequency notifications where latency permits.

## 18. Security and Anti-Exploit

> **The client expresses intent. The server determines truth.**

```text
Acceptable:  "I want to purchase Sword01."
             "I attempted to hit Player123."

Never trust:  "I bought Sword01 for 100 coins; my balance is 900."
              "I dealt 500 damage to Player123."
```

**This is the one area where "fewer lines" is never an excuse.** Simplicity must never mean removing validation, authority, rate limits, transaction integrity, or persistence safety. Security should be *centralized and clean*, not absent.

### Server authority is mandatory for

money · inventory · XP · levels · unlocks · purchases · rewards · trades · damage · match outcome · quest completion · loot · crafting · progression · cooldowns that gate value.

### Central remote guard

Do not let every handler invent its own security style. Build one small, reusable layer:

```text
server/security/
├── RemoteGuard.luau        schema + rate limit + dispatch
├── RateLimiter.luau        per-player, per-action token buckets
├── SuspicionTracker.luau   weighted signal accumulation
├── MovementValidator.luau
└── SecurityService.luau
```

```luau
-- Every C2S handler goes through one door.
RemoteGuard.Handle(Net.C2S.PurchaseItem, {
    RateLimit = { Burst = 5, PerSecond = 2 },
    Schema = {
        ItemId = RemoteGuard.String({ MaxLength = 64 }),
        Quantity = RemoteGuard.Integer({ Min = 1, Max = 99 }),
    },
}, function(player, payload)
    return EconomyService.PurchaseItem(player, payload.ItemId, payload.Quantity)
end)
```

Validation covers, as appropriate: type, structure, bounds, string and array length, permission, contextual state, distance, cooldown, and rate.

Length limits are not optional. An unbounded string or table from a client is a memory-exhaustion vector and a log-flooding vector.

### Rate limiting

Assume every endpoint will be called as fast as the network allows. Set **per-action** policies — purchase, trade, combat, interaction, and UI-backed requests all have different legitimate frequencies. One global throttle number is both too strict and too loose.

### Threat model before implementing

```text
What can the client lie about?
What happens if arguments are malformed, nil, NaN, or -0?
What happens at 1,000 calls per second?
Can this generate currency? Duplicate items?
Can it affect another player?
Can it trigger expensive server work? (unbounded loops, DataStore calls, instance creation)
Can distance or line-of-sight checks be bypassed?
Can timing be manipulated?
Can client-owned physics influence the outcome?
```

### Signals, suspicion, consequences

Most detections are **signals**, not proof. Latency, lag spikes, and legitimate edge cases produce false positives.

Signals worth tracking: impossible resource gain, impossible completion time, impossible movement, impossible attack rate, impossible interaction distance, invalid state transition, malformed request, repeated rate-limit violations, wrong-direction network call, honeypot activation, economy invariant failure, duplicate transaction behavior.

Weight them by severity and confidence, accumulate over time, and act on correlated evidence rather than a single event:

```text
1. Reject the request              (always — this is the real defense)
2. Correct authoritative state
3. Log with context
4. Increase suspicion score
5. Quietly restrict the exploitable capability
6. Kick
7. Temporary restriction
8. Ban
```

Never expose thresholds, never announce the detection to the client, and never state the reason precisely enough to be reverse-engineered.

### What does not work

- **Obfuscation is not security.** Assume every replicated ModuleScript is readable.
- **Hiding LocalScripts is not security.** Assume every remote can be fired with arbitrary arguments from a fake client.
- **Client-side detection is telemetry, not enforcement.** It can inform the server; it can never decide.
- **Honeypot remotes** (unused remotes a legitimate client never fires) are a useful high-confidence signal, never a primary defense.

### Network ownership and physics

Client network ownership of a part means the client dictates its position. For anything where position determines value — vehicles used to reach restricted areas, projectiles that deal damage, players triggering proximity rewards — either keep server ownership, or validate the resulting state server-side against physical plausibility.

### User-generated text must be filtered

Any text a player authors and another player can see — pet names, trade notes, guild names, custom signs, chat built on top of a custom UI — must pass through `TextService:FilterStringAsync` and be displayed via the appropriate `TextFilterResult` method for the audience (`GetNonChatStringForBroadcastAsync`, `GetNonChatStringForUserAsync`). This is a platform policy requirement, not a style preference. Filter on the server, store the raw string, and filter per-viewer at display time.

### Logging

Log enough to investigate: player ID, action, relevant IDs, server-resolved values, timestamp. Never log full player data structures, session tokens, API keys, or anything that would leak the shape of your detection logic into a place a curious player could read. Never spam Output thousands of times per second; that is its own denial of service.

## 19. Persistence, Economy, and Transactions

### One owner for persistent state

```text
Gameplay systems
      ↓  (request controlled mutations)
PlayerDataService          ← the only module that knows the schema
      ↓
PersistenceAdapter         ← the only module that calls DataStoreService
      ↓
DataStoreService
```

Dozens of modules calling `DataStoreService` independently is how games lose player data. There is exactly one adapter.

### Session ownership

For any game with an economy, inventory, or trading, **a player's data must be owned by exactly one server at a time.** Two servers writing the same profile is the root cause of most duplication exploits.

Implement session locking: on load, claim the profile (via `UpdateAsync` writing a session token and timestamp); refuse to load if another live session holds it; release on leave and on `BindToClose`. Handle the stale-lock case with a timeout so a crashed server does not permanently lock a player out.

This is one of the few places where using a well-maintained community library instead of writing it yourself is usually the correct call — session locking is subtle, and the failure mode is irreversible data loss.

### Atomic mutations

Use `UpdateAsync`, not `GetAsync` + `SetAsync`. The read-modify-write gap is exactly where duplication lives.

```luau
-- Wrong: two servers can both read 100, both write 150.
local coins = store:GetAsync(key)
store:SetAsync(key, coins + 50)

-- Right: the transform runs against the current value.
store:UpdateAsync(key, function(current)
    current = current or DEFAULT_PROFILE
    current.Coins += 50
    return current
end)
```

### Transactions are single operations

A purchase is one mutation, not two.

```luau
-- Wrong: currency and inventory can diverge on failure.
EconomyService.RemoveCoins(player, price)
InventoryService.AddItem(player, itemId)

-- Right: validate everything, then mutate once.
local result = PlayerDataService.Transact(player, function(profile)
    if profile.Coins < price then return nil, "InsufficientFunds" end
    if InventoryLogic.CountOf(profile) >= capacity then return nil, "InventoryFull" end
    profile.Coins -= price
    InventoryLogic.Add(profile, itemId, quantity)
    return profile
end)
```

Never subtract currency in one script and grant the item in another uncontrolled task.

For **trades**, both sides mutate atomically or neither does. Lock both profiles, validate both inventories at commit time (not at offer time), apply both changes, then release. Re-validate at commit — inventories change between offer and accept.

For cross-server coordination — trade locks, matchmaking, global limited-stock items — use `MemoryStoreService`, which is designed for it. Do not build a coordination system on top of a standard DataStore.

### Developer product receipts

`MarketplaceService.ProcessReceipt` **must be idempotent**. Roblox will re-deliver a receipt until you return `PurchaseGranted`, including across server restarts.

```luau
-- Record the PurchaseId as part of the same atomic mutation that grants the item.
-- If the PurchaseId is already recorded, return PurchaseGranted without granting again.
-- Return NotProcessedYet on any error so Roblox retries rather than consuming the purchase.
```

Grant first, persist the grant, *then* return `PurchaseGranted`. Returning it before the data is saved means a crash costs the player their purchase.

### Schemas and migration

Persistent data requires: a schema, defaults, a schema version, migrations, validation on load, an autosave policy, `BindToClose` handling, and defined failure behavior.

```luau
local CURRENT_VERSION = 4

local MIGRATIONS = {
    [1] = function(d) d.Inventory = d.Items; d.Items = nil; return d end,
    [2] = function(d) d.Settings = d.Settings or DEFAULT_SETTINGS; return d end,
    [3] = function(d) d.Coins = math.max(0, math.floor(d.Coins or 0)); return d end,
}
```

Never assume stored data matches the current game version. A profile written eighteen months ago will load tomorrow.

**Failure behavior must be explicit.** If data fails to load, the correct default is almost never "give the player a fresh empty profile" — that looks identical to total data loss. Prefer: retry, then reject the join with a clear message, or place the player in a clearly-marked non-persisting session. Never silently overwrite a profile you failed to read.

### Persistent vs transient

Separate them structurally. Session state (current zone, active UI, combat target, current fishing cast) lives in memory and dies with the session. Persistent state is a small, explicitly enumerated schema. If you cannot list what is saved, you are saving too much.

---

# PART V — WORLD AND CONTENT

---

## 20. World, Maps, and Streaming

Instance streaming is enabled by default for new places, and any large world should keep it on. Design for it from the first day; retrofitting streaming into a world built on the assumption that everything always exists is expensive.

### Relevant properties

```text
Workspace.StreamingEnabled          on by default for new places
Workspace.StreamingTargetRadius     max streaming distance (default 1024)
Workspace.StreamingMinRadius        highest-priority radius around the focus (default 64)
Workspace.StreamingIntegrityMode    PauseOutsideLoadedArea is the safe default
Workspace.StreamOutBehavior         Opportunistic is the usual choice
Workspace.PredictiveStreamingMode   proactive streaming ahead of movement
Workspace.EnableSLIMAvatars         generates simplified avatar models at distance

Model.ModelStreamingMode            Nonatomic (default) | Atomic | Persistent | PersistentPerPlayer
Model.LevelOfDetail                 Enum.ModelLevelOfDetail: Automatic | StreamingMesh | Disabled
Model:AddPersistentPlayer()         per-player persistence
Player:RequestStreamAroundAsync()   pre-fetch before a teleport or reveal
Workspace.PersistentLoaded          fires once persistent content has replicated
```

Use `Atomic` for models that are meaningless in pieces (a vehicle, an NPC assembly, a functioning door). Use `Persistent` sparingly — persistent content never streams out and must fully replicate before the player spawns, so it costs join time.

### Client code must not assume existence

Client systems interacting with world content must handle appearance, disappearance, and re-appearance. `WaitForChild` is appropriate here — this is precisely the case it exists for. Bind to `ChildAdded`/`ChildRemoved` or use CollectionService tags (which fire correctly as instances stream in and out) rather than caching a reference forever and assuming it stays valid.

### Organization for streaming

Structure the world into logical regions so the engine has natural chunks. Do not force large volumes of content to remain permanently loaded without a specific reason.

For radically different worlds or modes, prefer **separate Places** with `TeleportService` over one enormous Workspace. Accept the load-time cost in exchange for bounded memory per place. Multi-place is justified by genuinely disjoint content, not by a large single world that streaming handles fine.

### Do not crawl the world

```luau
-- Never in a loop, never per frame
for _, inst in workspace:GetDescendants() do ... end
```

A one-time startup scan is reasonable. Repeated scans are not. Use tags, registries, direct references, and event-driven registration instead.

## 21. Components, CollectionService, and Attributes

**Do not put a Script inside hundreds of world objects.** Tag them, and let one system drive behavior.

```text
CollectionService tag "Door"
        ↓
DoorComponent (one module)
        ↓
handles every tagged instance, including ones that stream in later
```

```luau
local function bind(instance: Instance)
    local doorId = instance:GetAttribute("DoorId")
    local locked = instance:GetAttribute("Locked")
    -- ...
end

for _, inst in CollectionService:GetTagged("Door") do bind(inst) end
CollectionService:GetInstanceAddedSignal("Door"):Connect(bind)
CollectionService:GetInstanceRemovedSignal("Door"):Connect(unbind)
```

Per-instance authored configuration goes in **Attributes**:

```text
Door
  DoorId          = "PoliceArmory"
  Locked          = true
  RequiredLevel   = 10
  AutoCloseTime   = 3
```

This replaces piles of ValueObjects and per-instance scripts, survives streaming, and is editable by a designer in Studio without touching code.

Typical tags: `Interactable`, `ShopNPC`, `QuestNPC`, `FishingZone`, `DamageVolume`, `Collectible`, `VehicleSpawner`, `Door`.

## 22. VFX

**The server decides what happened. The client decides what it looks like.**

```text
Server: explosion at position P, radius R, damage applied
   ↓ (one small S2C event: effect id + position + parameters)
Client: particles, lights, camera shake, debris, decals, sound
```

Do not replicate hundreds of cosmetic instances from the server. Do not let the server tween client UI or effects. Do not let a cosmetic effect determine an authoritative outcome — an animation marker or a particle collision is not proof of a hit.

```text
ReplicatedStorage/Assets/VFX/{Combat, Environment, Rewards, UI}

client/vfx/
├── VFXController.luau
├── EffectRegistry.luau
└── Effects/
```

**Pooling:** appropriate for *proven* high-frequency creation — projectiles, shell casings, hit markers, floating damage numbers, repeated NPC effects. Not appropriate by default. Pools introduce lifecycle complexity, reset bugs, and stale-state bugs; they must be paid for by profiling evidence.

Always clean up: disconnect connections, `Destroy()` emitters after their lifetime, cancel tweens, and release pooled objects on player leave or character removal.

## 23. Audio

Centralize through an `AudioController` with logical groups: Music, UI, Gameplay, Ambient, Vehicles, Characters. Route through `SoundGroup` instances so volume settings and ducking are one change, not two hundred.

Use 3D positional audio where the source has a position. Do not duplicate the same sound instance across hundreds of objects — play from a pooled or shared emitter. Do not preload the entire audio catalog; preload what the current context needs.

Player-facing volume settings, and a genuine mute, are accessibility features. Implement them.

## 24. Animation

Organize by character and domain (`Animations/{Player, NPC, Combat, Vehicles, ...}`) and reference IDs through the asset registry, never inline.

Load `Animation` instances once per `Animator` and cache the resulting `AnimationTrack`; repeatedly calling `LoadAnimation` leaks tracks.

Cosmetic animation is client-side. **Gameplay results tied to animation timing must be server-validated** — the server owns the damage window, not the client's animation marker. An exploiter can fire markers at will.

---

# PART VI — INTERFACE

---

## 25. UI Architecture

### Layers

Top-level interfaces are Layers, categorized by behavior:

```text
HUD       always-visible gameplay information
Menu      full-screen navigable screens (Inventory, Shop, Quests)
Modal     blocking dialogs (Confirm Purchase, Trade Offer)
Overlay   non-blocking transient (Notifications, Toasts)
System    Loading, Error, Reconnect
```

### One router

```text
client/ui/
├── UIController.luau
├── UIRouter.luau            open/close, history, transitions
├── ModalController.luau     modal stack
├── NotificationController.luau
├── InputModeController.luau
├── Theme.luau
├── Layers/
└── Components/
```

The router owns screen visibility, menu history, modal stacking, back behavior, HUD suppression, transition state, and input capture. **Individual features must not toggle unrelated ScreenGuis.** The moment two systems both hide the HUD, you get a permanently hidden HUD.

Menus use a stack:

```text
MainMenu → Inventory → ItemDetails
Back:      ItemDetails → Inventory → MainMenu
```

One back implementation, not a chain of screen-specific hacks.

### References

Never scatter deep paths:

```luau
-- Bad, everywhere
PlayerGui.Main.Frame.Frame.Container.Frame.Button
```

Each controller resolves and validates its references once, and fails loudly in development when a required code-facing node is missing:

```luau
local function view(root: ScreenGui)
    return {
        Root         = root,
        CloseButton  = assert(root:FindFirstChild("CloseButton", true), "InventoryLayer: CloseButton missing"),
        ItemList     = assert(root:FindFirstChild("ItemList", true), "InventoryLayer: ItemList missing"),
        SearchInput  = assert(root:FindFirstChild("SearchInput", true), "InventoryLayer: SearchInput missing"),
    }
end
```

A missing UI node should be a loud error during development, not a silent nil that manifests as a dead button in production.

### State, not polling

```luau
-- Bad
while task.wait(0.1) do
    moneyLabel.Text = tostring(getCoins())
end

-- Good
EconomyState.CoinsChanged:Connect(function(newValue)
    moneyLabel.Text = Format.Currency(newValue)
end)
```

UI reacts to state changes. Currency displays do not need `RenderStepped`. Inventory does not need `Heartbeat`.

Do not build one gigantic global table holding every UI variable in the game. State lives with the domain that owns it; UI subscribes.

### Components

Extract a component when behavior or design **actually repeats**: `PrimaryButton`, `ItemCard`, `CurrencyDisplay`, `Tooltip`, `TabButton`, `ProgressBar`, `Toast`, `ConfirmationModal`.

A component may wrap an imported Figma hierarchy — that is the normal case, not a compromise.

**Not every element needs a class.** A screen controller binding its own `CloseButton` and `PurchaseButton` directly is correct. Three button classes for three one-off buttons is not.

### Naming

```text
Screens:     InventoryLayer, ShopLayer, TradingLayer, SettingsLayer
Templates:   ItemCardTemplate, PlayerRowTemplate, RewardCardTemplate
Structure:   Root, Header, Body, Footer, Content, Sidebar
Elements:    TitleLabel, DescriptionLabel, IconImage, CloseButton,
             PurchaseButton, ItemList, SearchInput, EmptyState, LoadingState
```

Code-facing nodes must never remain named `Frame`, `Frame1`, `TextLabel`, `ImageLabel14`, `Group 273`, or `Rectangle 481`.

## 26. Figma Workflow

**Figma is a first-class production source, not a shortcut.**

The imported visual hierarchy **is the View**. Runtime behavior lives in filesystem `.luau` modules. These are different things and neither replaces the other.

```text
Figma
  ↓ importer plugin (FigBloxUI, RoImport, or similar third-party tool —
    Roblox ships no first-party Figma importer)
Imported Roblox GUI hierarchy
  ↓
Semantic cleanup of code-facing nodes only
  ↓
UI Layer / Component classification
  ↓
Controller in src/client/ui/ binds behavior
  ↓
Feature state
```

### Import procedure

1. Inspect the imported hierarchy (Studio MCP, targeted — see §38).
2. Remove importer artifacts that serve no runtime purpose, and any scripts an importer inserted.
3. **Preserve intentional layout objects.** `UIListLayout`, `UIPadding`, `UIAspectRatioConstraint`, and auto-layout translations survive import and are the responsive foundation. Do not delete them.
4. Rename **interactive, stateful, and code-facing** nodes semantically.
5. **Do not rename decorative descendants.** A background gradient frame named `Rectangle 481` is fine forever if no code touches it.
6. Extract genuinely reusable pieces as components/templates.
7. Assign it to a UI Layer.
8. Bind it through the router and a controller.
9. Add responsive behavior (§28).
10. Add gamepad and touch support if the game targets those platforms.
11. Test across resolutions and aspect ratios.
12. Version the resulting prefab as a Rojo-managed `.rbxmx` under `assets/replicated/UI/` so the design is in Git.

### What survives import, what does not

Import fidelity varies by tool and changes over time. Verify against your importer rather than assuming. In general, auto-layout, gradients, strokes, and text styles translate reasonably; Figma components, variants, and effects often do not survive as structured concepts, and layer names become instance names.

Since Roblox's full release of native UI shadows and per-corner radii (§27), importers can map those directly instead of emitting 9-sliced images — enable the corresponding option if your importer supports it, because native `UIShadow` outperforms 9-sliced `ImageLabel` shadows.

### Do not rebuild good imported UI in code

If the import produced a correct hierarchy, **bind to it**. Do not recreate the interface with `Instance.new()` because generating code is easier than reading a tree. Do not restructure the hierarchy, recreate components, or alter visual values while implementing logic.

Normalize only what affects: code references, responsiveness, input/accessibility, reuse, runtime state, or maintainability.

> **UI cleanup is not a redesign.** Preserve visual fidelity unless a redesign was requested.

## 27. Design System and Tokens

Centralize repeated visual values **when the project benefits**. A game with three screens does not need a token framework. A game with thirty screens needs one badly.

```text
UITheme
├── Colors        semantic roles, not raw swatches
├── Typography    font, sizes, weights, line height
├── Spacing       one scale, used everywhere
├── CornerRadius
├── Stroke
├── Shadow
├── Animation     durations and easing
├── Sounds        UI feedback
└── Icons
```

```luau
-- shared/ui/Theme.luau
return {
    Colors = {
        Surface       = Color3.fromHex("1B1E24"),
        SurfaceRaised = Color3.fromHex("242832"),
        TextPrimary   = Color3.fromHex("F2F4F8"),
        TextMuted     = Color3.fromHex("9AA3B2"),
        Accent        = Color3.fromHex("F2B33D"),
        Danger        = Color3.fromHex("D14B4B"),
        Success       = Color3.fromHex("4BA96B"),
    },
    Spacing     = { XS = 4, SM = 8, MD = 12, LG = 20, XL = 32 },
    Radius      = { SM = 4, MD = 8, LG = 16, Pill = 999 },
    Typography  = {
        Display = { Font = Enum.Font.FredokaOne, Size = 34 },
        Title   = { Font = Enum.Font.GothamBold,  Size = 22 },
        Body    = { Font = Enum.Font.Gotham,      Size = 16 },
        Caption = { Font = Enum.Font.Gotham,      Size = 13 },
    },
    Animation   = { Fast = 0.12, Base = 0.2, Slow = 0.35, Ease = Enum.EasingStyle.Quad },
}
```

Name colors by **role** (`Surface`, `TextMuted`, `Danger`), not by appearance (`DarkGrey`, `Blue2`). Roles survive a palette change; appearances do not.

### Native shadows and corners

Roblox now provides these natively (full release, mid-2026):

```text
UICorner.TopLeftRadius / TopRightRadius / BottomLeftRadius / BottomRightRadius  (UDim)
UICorner.CornerRadius   — now an alias that sets all four

UIShadow.BlurRadius (UDim), Color, Transparency, Offset (UDim2),
        Spread, ZIndex (negative only), Enabled
```

`UIShadow` is consistently faster than a 9-sliced `ImageLabel`. Roblox's own guidance is to stay under roughly **100 on-screen UIShadows** at once — that is a platform recommendation, so treat it as a real constraint rather than an invented rule.

Map your Shadow and CornerRadius tokens onto these directly. Do not hand-roll shadow images anymore unless a specific art direction requires it.

### The token rule

- **Do not** hardcode the same color, duration, or corner radius in dozens of unrelated controllers.
- **Do not** build a token system with theme inheritance, runtime overrides, and a variant resolver for a project with one theme.

Start with a flat table. Grow it only when the project's actual variance demands it.

## 28. Responsive UI, Input, Localization, Accessibility

**Responsiveness is part of implementation, not a cleanup pass after the desktop version ships.**

### Layout

Use the engine's layout systems rather than hardcoding coordinates:

```text
UIListLayout · UIGridLayout · UIPadding · UIFlexItem
UIAspectRatioConstraint · UISizeConstraint · UITextSizeConstraint · UIScale
```

Prefer `Scale` for positioning and container sizing, `Offset` for things that must stay physically constant (icon sizes, stroke widths, minimum touch targets). Do not copy Figma's pixel measurements across all devices — a 1920×1080 mockup is one target, not the spec.

Test at minimum: phone portrait, phone landscape, tablet, 16:9 desktop, ultrawide, and console safe area. `GuiService:GetGuiInset()` and the `TopbarInset` matter; content under the Roblox topbar is content nobody can tap.

### Input

Buttons respond to `Activated`, not `MouseButton1Click`, so touch and gamepad work without a second code path. Centralize action bindings through `ContextActionService` rather than scattering `UserInputService` listeners.

```text
Inventory opens → gameplay input suppressed, UI navigation enabled, GuiService selection set
Inventory closes → previous input context restored
```

If the game targets console, set `SelectionGroup`/`NextSelection*` so a controller can traverse the UI, and give every focusable control a visible selection state. React to `UserInputService.LastInputTypeChanged` to swap prompt glyphs between keyboard, gamepad, and touch.

Minimum touch targets matter. A 20-pixel close button is usable with a mouse and unusable with a thumb; keep interactive targets comfortably large in offset terms on touch.

### Localization

Do not build localization infrastructure for content that will never be localized. **But do not architect UI in a way that makes future localization painful.** The cost difference between the two is almost zero if you decide up front.

```text
Cheap now, expensive later:
  - user-facing strings living in one place (a table or a LocalizationTable), not inline in 40 controllers
  - layouts that grow with text: AutomaticSize, UIListLayout, no fixed-width buttons sized to English
  - numbers, dates, and currency formatted through one helper
  - no sentences assembled from concatenated fragments ("You caught " .. n .. " fish")
    — use one parameterized string per message
```

Roblox provides automatic text capture plus `LocalizationService`. Two distinct APIs, commonly confused:

```luau
-- Source-string based (works with automatic capture):
translator:Translate(contextInstance, "Open Shop")

-- Key based (explicit LocalizationTable entries, supports parameters):
translator:FormatByKey("shop.title", { count = 3 })
```

Key-based is the better foundation for a game that intends to localize. `GuiObject.AutoLocalize` controls whether automatic capture applies to a given element.

### Accessibility

- **Text must be readable.** Respect the platform's preferred text size where possible; do not ship 11px body text.
- **Contrast must be sufficient** against the actual background, including over busy 3D scenes — that is what `UIStroke` on text and semi-opaque backing plates are for.
- **Never communicate meaning through color alone.** Rarity, team, status, and error states get an icon, a label, or a shape in addition to a hue. Roughly one in twelve men has some form of color vision deficiency.
- **Do not require rapid or precise input** for essential progression without an alternative.
- **Respect reduced motion** where the platform exposes it; avoid full-screen flashing and rapid strobing entirely.

---

## 29. Anti-AI UI Design Rules

This section exists because AI-generated interfaces have a recognizable, bad default aesthetic, and because Roblox is not the web.

The failure mode is well understood: a language model asked to "design a UI" with no constraints reproduces the statistical center of its training data — the generic SaaS dashboard. That center is not this game's design language.

### Forbidden defaults

Do not produce, unless the game's existing design language actually calls for it:

```text
cards inside cards inside cards
a rounded container around every single element
uniformly huge corner radii on everything
gradients as a default surface treatment
blue / purple / cyan palettes chosen because they are "modern"
glow on elements that are not emphasized
drop shadows on every layer
bounce or elastic easing on ordinary transitions
animation on elements that have no reason to move
giant headings with no hierarchy beneath them
explanatory paragraphs under headings that need none
verbose button labels ("Click here to purchase this item now")
a fresh spacing scale invented per screen
three fonts because variety felt right
generic mobile-app or web-dashboard aesthetics
web SaaS patterns transplanted wholesale into a Roblox game
```

Roblox games have their own visual traditions — chunky outlined type, saturated palettes, heavy strokes, stylized iconography, physical-feeling buttons. A Roblox shop UI that looks like a Stripe dashboard is wrong even if it is technically clean.

### Order of authority

Before making any visual decision, consult, in this order:

```text
1. The game's Figma file
2. Screenshots or visual references the user provided
3. Existing implemented screens in this game
4. Established components and templates in this project
5. The project's design tokens (Theme.luau)
6. Roblox's broader visual conventions for this genre
7. Only then: your own judgment
```

**If a visual reference exists, match its language before introducing anything new.** If multiple references exist, infer the shared system between them — spacing rhythm, radius scale, stroke weight, type ramp, palette roles — and extend that system rather than inventing a parallel one.

**Never improvise a design language for a game that already has one.** Adding a screen means extending the existing system, not showcasing an alternative.

### When no reference exists

If the user has provided no reference and no design system exists yet, do not silently invent one and build twelve screens on it. Build one screen, state the visual decisions you made and why, and ask for direction. A design language is the user's call.

### Copy discipline

Interface text is design. Apply the same restraint:

```text
Bad:  "Please ensure that all required fields have been correctly filled in"
Good: "Complete all fields"

Bad:  "Click here to purchase this item now"
Good: "Buy"                     (or "Buy — 250")

Bad:  A heading, a subheading, and a paragraph explaining what an obvious button does
Good: The button
```

Labels are short. Errors say what happened and what to do. Nothing explains what the UI already shows.

### Visual restraint checklist

Before delivering UI work, verify:

- Does every container earn its existence, or is this a box inside a box?
- Is there a clear primary action, or do five elements compete for attention?
- Is spacing on the project's scale, or ad hoc per element?
- Does every animation communicate something (state change, causality, direction)?
- Is the palette this game's palette?
- Does anything move, glow, or pulse without a reason?
- Would this screen be recognizable as belonging to this game with the logo removed?

If the honest answer to the last question is no, it is wrong regardless of how clean it looks.

## 30. Visual Verification

When implementing UI against **an existing Figma design, screenshot, image, reference, or established screen**, comparing the result to the reference is part of the job — not an optional extra.

Where tooling permits (Studio MCP screen capture, playtest screenshots, side-by-side inspection), compare:

```text
hierarchy and structure     proportions and relative sizing
spacing and rhythm          alignment
colors                      typography (family, size, weight, case)
icon sizing                 corner radii
stroke weights              shadow depth and direction
visual density              responsive behavior at 2–3 breakpoints
```

Then state what differs and fix it.

> **"Looks approximately correct" is not acceptable when a direct visual reference exists and verification is reasonably possible.**

### Proportionality

This is a comparison discipline, not an infrastructure project.

- Changing one button's color: look at it, confirm, done.
- Implementing a full shop screen from Figma: capture, compare against the reference systematically, fix the deltas, capture again.
- **Do not build an automated visual regression framework** unless the project has enough UI churn and enough screens to justify one, and the user asked for it.

Match the verification effort to the size and risk of the change.

---

# PART VII — QUALITY

---

## 31. Performance

Performance is architectural. It is decided when systems are designed, not discovered at launch when every NPC is doing twenty hierarchy scans per frame.

**But do not optimize without evidence.**

```text
write clear code → measure → identify the actual bottleneck → fix it → measure again
```

### Architectural rules that are always right

These cost nothing and prevent the common disasters:

- **Event-driven over polling.** If an event exists, use it.
- **No ordinary logic on `RenderStepped`/`Heartbeat`/`PreSimulation`/`PostSimulation`.** These are for camera work, prediction, and frame-timed visuals. Currency UI does not need a frame loop. Inventory does not need `Heartbeat`. Use the lowest update frequency that works.
- **No repeated hierarchy scans.** Cache references, use tags, use registries.
- **Cache what you look up constantly.** `workspace.CurrentCamera` in a local is free.
- **Disconnect what you connect.** See §32.
- **Stagger expensive work.** Do not run every NPC's decision update on the same frame; distribute across a window.
- **Spatially partition.** Never compare every entity to every other entity every frame. Use zones, radius queries, `OverlapParams`-based spatial queries, or a grid. Watch the complexity class as entity counts grow.
- **Send deltas, not full state.** See §17.

### NPCs at scale

Spawn on demand, cull when out of range, disable unneeded `Humanoid` state types, prefer `AnimationController` when a `Humanoid` is unnecessary, stagger AI updates, and pool only with evidence. Design for the target population, not the five NPCs in the test place.

### Rendering and instances

Watch instance count, draw calls, transparency overdraw, and UI layer depth. Semi-transparent surfaces cost more than opaque ones. Deep `ZIndex` stacks and large numbers of `UIStroke`/`UIGradient` objects add up. Reuse meshes and textures so the engine can batch.

For meshes, `MeshPart.RenderFidelity` controls detail cost; `Enum.ModelLevelOfDetail` controls model-level LOD under streaming. These are real properties — do not confuse them with streaming settings.

### Profiling

Use the actual tools before guessing:

```text
MicroProfiler (Ctrl+F6 / Ctrl+Shift+F6)   frame breakdown
Developer Console (F9)                     memory categories, network, script activity
Performance Stats (Shift+F2)               live counters
debug.profilebegin() / debug.profileend()  custom scopes around your own systems
```

### Budgets, not universal numbers

**This document does not impose universal performance thresholds.** Numbers like "under 1,000 draw calls" or "under one million triangles" are *examples of a budget for one device and one genre*, not laws. A stylized 2D-ish obby and a dense open-world shooter have nothing in common.

Instead: **pick a baseline target device, measure it, and write project-specific budgets into `ARCHITECTURE.md`:**

```text
server frame time      client frame time (target device)
memory ceiling         network throughput per player
max concurrent NPCs    max runtime instance count
join-to-playable time  remote call frequency per player
```

The only numbers this document treats as constraints are actual platform constraints — engine limits and Roblox's own published recommendations, cited as such.

### Loading

`ReplicatedFirst` holds only what the first frame needs. Prioritize the loading screen, immediate menu assets, spawn-area content, and immediately required sounds and models. `ContentProvider:PreloadAsync` for what the player is about to see — not the whole catalog.

## 32. Memory and Cleanup

Anything that creates a long-lived resource defines its cleanup. Every time.

Clean up: `RBXScriptConnection`s, running tasks, observers, temporary Instances, table entries, cached references, temporary UI, component state, tween handles.

A focused ownership helper (Maid/Janitor/Trove style) is welcome. What matters is **deterministic lifecycle ownership**, not which library provides it.

```luau
function Component.new(instance: Instance)
    local self = setmetatable({ _conns = {} }, Component)
    table.insert(self._conns, instance.AncestryChanged:Connect(...))
    return self
end

function Component:Destroy()
    for _, c in self._conns do c:Disconnect() end
    table.clear(self._conns)
end
```

### Player cleanup

On `PlayerRemoving`, release everything keyed to that player: session state, cached references, connections, running tasks, security state, and owned runtime instances. Then release the persistence session lock.

A departed player referenced in a table forever is a memory leak with a slow fuse. Since `Player` objects hold references to their character, GUI, and everything you attached to them, one stale entry can retain a great deal.

Use a single per-player state table with one teardown path, rather than eleven modules each remembering to clean up.

## 33. Testing

**Testing effort corresponds to risk.**

### High value

Deterministic, high-consequence logic that can run without the DataModel:

```text
economy calculations       reward calculations
XP and level curves        rebirth / prestige formulas
damage formulas            loot and rarity rolls
crafting rules             inventory capacity logic
transaction validation     remote payload validators
serialization              schema migrations
```

Write these as pure functions over plain data so they are testable without spawning half the game. That constraint improves the design independently of testing.

```luau
-- Testable: pure, no Instances, no services
function CatchMath.RollWeight(definition: FishDefinition, luck: number, rng: Random): number
    ...
end
```

### Low or negative value

```text
getters                                    trivial glue
tests that mock half of Roblox             tests written to raise a coverage number
tests that assert the implementation       tests that special-case their way to green
```

**Never hardcode a path to make a test pass.** Implement the actual rule. A test that passes because the code detected it was under test is worse than no test.

### Framework

Either **TestEZ** (long-established, widely used, effectively in maintenance) or **Jest Lua** (modern, Jest-compatible API, actively developed) is a reasonable choice. Pick one per project. Run headless in CI via `run-in-roblox` or an equivalent runner.

## 34. Analytics, Observability, and LiveOps

### Logging

Use consistent categories: `Server`, `Persistence`, `Economy`, `Security`, `Network`, `World`, `Analytics`. Include enough context to investigate a failure — IDs, server-resolved values, timestamps.

Never dump full player data structures. Never log secrets. Never spam Output.

### Analytics

Route through **one adapter**, so gameplay modules do not import an analytics vendor:

```luau
-- shared/analytics/Analytics.luau — one boundary
Analytics.Track("FirstPurchase", player, { ItemId = itemId, Price = price })
```

Roblox's `AnalyticsService` provides the current surface:

```text
LogCustomEvent(player, eventName, value, customFields)
LogEconomyEvent(player, flowType, currencyType, amount, endingBalance,
                transactionType, itemSku, customFields)
LogFunnelStepEvent(player, funnelName, funnelSessionId, step, stepName, customFields)
LogOnboardingFunnelStepEvent(player, step, stepName, customFields)
LogProgressionEvent / LogProgressionStartEvent /
LogProgressionCompleteEvent / LogProgressionFailEvent
```

`FireCustomEvent`, `FireEvent`, `FireInGameEconomyEvent`, and `FireLogEvent` are **deprecated** — do not use them.

Instrument what actually informs decisions: onboarding funnel, first purchase, first meaningful progression milestone, session milestones, shop opens, conversion points, errors, and suspicious-activity counts. Do not instrument everything; a dashboard nobody reads is a cost with no return.

### LiveOps

Recurring content — events, seasons, shop rotations, boosts, limited items — belongs in configuration and registries with explicit date ranges, not hardcoded across modules. A season should be a data change and a deploy, not a code hunt.

### Feature flags

For high-risk systems, one small centralized flag module with an obvious default is worth it. Do not scatter arbitrary booleans across unrelated files, and do not build a remote-config service for a game with two flags.

---

# PART VIII — PROCESS

---

## 35. Git and Collaboration

Git is mandatory. Scale the *process* to the team, not the ambition.

| | Solo prototype | Solo serious project | Small team | Larger team |
|---|---|---|---|---|
| Branches | optional | feature branches | feature branches | feature branches + protected main |
| PRs | no | optional | yes | yes, required review |
| Review | self, via diff | self, via diff | peer | peer + domain owner |
| CI | none | format + lint | + types + tests | + build validation |
| Ownership | implicit | ARCHITECTURE.md | CODEOWNERS | CODEOWNERS + design review |

**Do not create bureaucracy for a solo prototype. Do not skip review on a live game with an economy.**

### Commits

Meaningful, focused, logically bounded:

```text
Good:  Add server-authoritative fishing rewards
       Fix inventory capacity check off-by-one
       Bind Figma-imported shop layer to ShopController
       Add rate limiting to trade remotes

Bad:   stuff / changes / fix / asdf / wip
```

Before major changes: `git status`, `git diff`. Never destroy unrelated uncommitted work. Never force-push shared history without an explicit reason and a heads-up.

### Diff hygiene

Avoid whole-file rewrites. Do not reorder or reformat unrelated code while fixing something small. Separate unrelated changes. Keep formatting deterministic — that is what StyLua is for, and it should run on save.

### Ownership

Record which domains belong to whom in `ARCHITECTURE.md` (and `CODEOWNERS` if the team is large enough). High-risk areas — economy, persistence, security, monetization — should require review from their owner regardless of team size.

### Roblox-side collaboration

Team Create and Creator Dashboard permissions control **place** access; Git controls **code** access. Keep both intentional: grant Studio edit rights only to people who need to author assets or maps, and remember that anyone with Studio edit access can bypass your Git review entirely by editing in place. This is a real reason to keep script source out of Studio.

## 36. CI, Build, and Deployment Readiness

**Structure the repository so automation can be added later without surgery. Do not build a CI cathedral for a small project.**

### The ladder

Add rungs as the project earns them:

```text
1. Format check      stylua --check
2. Lint              selene src
3. Type analysis     luau-lsp analyze (with a generated sourcemap)
4. Tests             run the deterministic suite
5. Build validation  rojo build default.project.json -o build.rbxl
6. Publish           Open Cloud place publishing
```

Rungs 1–2 are worth it on day one; they cost minutes and prevent a category of review noise permanently. A formatting or type failure should never require opening Studio to discover.

### Publishing

Roblox Open Cloud supports programmatic place publishing:

```text
POST https://apis.roblox.com/universes/v1/{universeId}/places/{placeId}/versions?versionType=Published
Header:  x-api-key: <key>
Body:    the built .rbxl (application/octet-stream) or .rbxlx (application/xml)
```

The API key needs the `universe-places` permission with Write access for the target universe, created in the Creator Dashboard. Store it as a repository secret; never commit it.

Verify current endpoint and scope details against Roblox's Open Cloud documentation before wiring a pipeline — Open Cloud evolves, and a stale endpoint fails loudly at the worst time.

### Sensible deployment shape

```text
feature branch → PR → checks pass → review → merge to main
                                              ↓
                                    publish to a staging place
                                              ↓
                                    verify, then publish to production
```

Do not auto-publish to production on every merge for a live game with an economy. A human should decide when players get a new build.

## 37. Claude Code Workflow

### Before writing code

```text
1.  Understand the requested change.
2.  Search the repository for the relevant system.
3.  Identify the owning domain.
4.  Inspect the existing implementation.
5.  Look for reusable code, config, or components.
6.  Determine server / client / shared responsibility.
7.  Consider network implications, when relevant.
8.  Consider persistence implications, when relevant.
9.  Consider security boundaries, when relevant.
10. Consider performance, when genuinely relevant.
11. Make the smallest robust change.
12. Verify proportionally.
```

Steps 7–10 are *conditional*. A button color change does not have network implications, and pretending it does wastes everyone's time.

**Do not reread the entire repository for every task.** Targeted inspection:

```text
search for the symbol → identify the owner → read the relevant files
→ follow references only as far as needed
```

**Do not speculate about unread code.** If the bug is in `FishingService`, read `FishingService` and its callers before naming a cause.

### Match process to task size

```text
"Change the shop button sound."
  → find the asset reference → change it → verify
  NOT: launch subagents, write an investigation report, refactor the audio architecture

"Add server-authoritative trading."
  → threat model → contracts → persistence design → implementation → tests → playtest
```

### Subagents

Use them when work can genuinely proceed independently, when a large investigation benefits from isolated context, or when multiple substantial workstreams can run in parallel.

Do not use them for one-file edits, simple searches, straightforward bug fixes, or short sequential tasks.

### Standard feature flow

```text
Request
  → identify domain
  → search repository
  → inspect relevant architecture
  → security / performance consideration where relevant
  → implement in local .luau
  → Rojo syncs
  → Studio MCP where Studio awareness is needed
  → playtest
  → fix filesystem source (never Studio source)
  → format, lint, test
  → review the Git diff
```

## 38. Roblox Studio MCP Workflow

Studio MCP is Claude's window into the live DataModel. It is **not the script editor**.

### Default to the filesystem. Escalate to MCP only when Studio is genuinely required.

> **Rojo and VS Code first. Studio MCP only when the task cannot be answered or completed from the filesystem.**

This is a hard default, not a token-saving tip. Before any MCP call, ask:

```text
Can I answer this by searching the repository?          → do that instead
Can I answer this by reading a .luau file?              → do that instead
Can I make this change by editing a .luau file?         → do that instead
Does this genuinely require the live DataModel,
  a Studio-authored instance, or a running game?        → now use MCP
```

Reaching for MCP when a `grep` would have answered the question is the same mistake as
reading the whole repository for a one-line fix: disproportionate tooling.

```text
Task                                          Correct tool
-------------------------------------------   ---------------------------
"Why does the purchase fail?"                 repository search → read the service
"Change the shop button sound"                edit the asset registry file
"Add a rate limit to this remote"             edit the security module
"Rename a service"                            filesystem + Git
"What is the shop UI hierarchy?"              MCP — Studio owns that tree
"Does this Figma import look right?"          MCP — screen capture
"What tags are on the map doors?"             MCP — authored instance data
"Is the round actually starting?"             MCP — playtest and runtime state
```

### Use it for

```text
inspecting DataModel hierarchy       inspecting Figma-imported UI
creating / moving Instances          configuring properties
models, tags, attributes             Workspace and map objects
Lighting, audio, VFX authoring       runtime state inspection
playtesting                          Studio-specific debugging
screen capture for visual verification
```

### Never use it for

```text
editing the source of a Rojo-managed script
```

That creates a second source of truth. See §6.

### Token discipline

Do not dump the entire DataModel. Do not retrieve every property of thousands of Instances. Do not repeatedly enumerate `Workspace`, `ReplicatedStorage`, or `ServerScriptService` wholesale.

```text
Good:  find ShopLayer under ReplicatedStorage.Assets.UI, then inspect its children
Bad:   return every Instance in the game
```

The escalation order above applies to *how much* you inspect as well as *whether* you inspect:

```text
repository search → relevant file read → targeted Studio inspection of one subtree
```

Tool usage is proportional to the task, exactly like verification.

### Figma + Claude + MCP flow

```text
Figma
  → import to Studio
  → Claude inspects the imported hierarchy via MCP (targeted)
  → Claude identifies Layer + reusable Components
  → Claude renames only code-facing nodes
  → Claude writes controllers as local .luau files
  → Rojo syncs code
  → playtest + screen capture verification
  → Claude fixes local source
  → Git diff review
```

Gameplay logic never lives inside imported GUI instances.

---

## 39. AI Coding Discipline

Claude is a senior engineer maintaining a production codebase. Claude is **not** demonstrating intelligence by generating the maximum number of files, modules, classes, comments, or architectural layers.

> **Solve the actual problem with the smallest clean solution that fits the existing architecture.**

More code is not better. More modules are not better. More abstractions are not better. More comments are not better. More validation is not better. More documentation is not better. More architecture is not better.

### 39.1 Existing code first

Before creating anything, **search for what already owns the responsibility.**

Never create a second: inventory system · notification system · UI router · state store · asset registry · networking layer · rate limiter · cleanup helper · currency formatter · analytics wrapper.

Extend the existing architecture unless it is demonstrably broken. If the project uses `InventoryService` / `InventoryController` / `InventoryLayer` / `InventoryConfig`, do not introduce `InventoryProvider` / `InventoryRepository` / `InventoryInteractor` for one feature. **Consistency outranks architectural novelty.**

### 39.2 Minimal diff

Do not modify unrelated working code. Do not perform unsolicited repository-wide cleanup. Do not rename unrelated files. Do not reformat directories because one feature changed. Do not convert working architecture to a preferred architecture without being asked. Do not perform aesthetic refactors disguised as necessary work.

> **A bug fix is not permission to renovate the neighborhood.**

Asked to "fix the shop purchase bug," do not also rewrite `ShopService`, rename fourteen files, replace the networking layer, redesign `InventoryService`, invent a transaction framework, and rewrite the docs.

Refactor when: the task requires it, the current architecture prevents a correct implementation, there is a concrete maintainability problem, duplication is actively causing bugs, or debt is directly blocking the work. Not because another pattern looks nicer.

### 39.3 New file check

> **Does this concept genuinely deserve independent ownership?**

Create a module when it has an independent responsibility, real reuse, significant isolated logic, a meaningful domain boundary, a separately testable algorithm, or it relieves a genuinely oversized file. A twelve-line helper usually belongs with its caller.

Avoid both extremes: god modules that own unrelated domains, and hundreds of microscopic fifteen-line files that turn reading code into tab archaeology. **Optimize for navigability and ownership, not file count.**

Warning signs of a god module: thousands of lines, unrelated functionality, a sprawling public API, many unrelated reasons to change, excessive dependencies.

Avoid catch-all dumps (`Utils.luau`, `Helpers.luau`, `Misc.luau`) with hundreds of unrelated functions. Focused utilities (`TableUtil`, `TimeUtil`) are fine. Domain-specific helpers stay with their domain.

### 39.4 Abstraction check

Before introducing an abstraction, answer all five:

```text
1. What concrete problem does it solve?
2. Does that problem exist now?
3. Does an existing abstraction already solve it?
4. Will it reduce more complexity than it introduces?
5. Is there more than one meaningful consumer, or another strong reason it must exist?
```

Weak answers mean no.

```text
Bad:                                 Good when sufficient:
PurchaseButton                       PurchaseButton
  → PurchaseButtonAdapter              → ShopController
  → PurchaseActionProvider             → EconomyService
  → ShopCommandBus
  → ShopService
```

### 39.5 Do not design for fantasy requirements

Do not build: plugin systems nobody requested · generic framework layers for hypothetical features · enterprise dependency injection · event buses for five modules · universal repositories · command frameworks · factories everywhere · strategy objects for trivial branching · state machines for simple booleans · wrappers around straightforward Roblox APIs · adapters that rename a function · complex async pipelines without need · caches without evidence · object pools without evidence · configuration engines for static constants.

Do not build because "maybe we'll support forty currencies," "maybe we'll need plugins," "maybe this becomes cross-game."

Design natural extension points. Do not build speculative machinery.

### 39.6 Do not rebuild Roblox

Check whether the engine already solves it: `CollectionService` · Attributes · `ContextActionService` · `ContentProvider` · `TweenService` · `MemoryStoreService` · `MessagingService` · streaming · spatial query APIs · `LocalizationService` · Packages · `Actor`/parallel Luau.

Wrap a Roblox API only when the wrapper adds real ownership, safety, testability, portability, or meaningfully repeated behavior. `PlayersAdapter`, `WorkspaceProxy`, `TweenServiceWrapper`, and `InstanceCreationService` add none of those.

### 39.7 Do not make everything a class

Not every fish, button, config, item definition, or utility needs `.new()`, a metatable, `__index`, and `Destroy()`. Use object patterns when instances have meaningful behavior *and* lifecycle. Otherwise: plain data and functions.

Similarly: state machines are for genuinely complex transitions, not `menuOpen = true`. Parameter objects are for APIs with many optional arguments, not `damage(target, amount)`.

### 39.8 Error handling discipline

**`pcall` is for boundaries where failure is expected** — DataStore, HTTP, `MarketplaceService`, external APIs documented to throw. It is not a way to make a bug stop printing.

```luau
-- Wrong: this hides a real defect
pcall(function() inventory[itemId] += 1 end)
```

**Do not create silent fallbacks for impossible internal states.** If a required registry entry is missing, that is a content bug — assert, warn clearly, or fail. Do not silently substitute an empty table and ship a game where items vanish.

**Do not retry logic bugs.** Retries are for transient failures. Nil indexing, wrong arguments, missing modules, and broken hierarchies do not improve on the fifth attempt.

**Validate at boundaries, not at every line:**

```text
RemoteGuard validates the payload      ← untrusted input
      ↓
ShopService validates business rules   ← domain invariants
      ↓
Inventory performs a trusted mutation  ← no revalidation
```

Avoid validation pyramids where the same check runs five times across trusted internal calls.

### 39.9 Timing discipline

**`WaitForChild` where waiting is genuinely necessary** — replication, streaming, runtime-spawned instances, `PlayerGui` population. Not mechanically chained across every deterministic Rojo-managed path.

**No arbitrary `task.wait(n)` to fix races.** If ordering matters, express it: deterministic initialization, a readiness signal, an explicit lifecycle phase, or an availability check.

**Events over polling.** Poll only when the problem genuinely requires sampling.

### 39.10 Human-written production code

Claude-generated code must not announce itself. Avoid:

```text
comments on every line                     docblocks on obvious functions
absurdly verbose variable names            needless wrapper layers
excessive defensive checks                 dozens of tiny modules
excessive configuration                    patterns used for prestige
giant catch-all services                   repetitive boilerplate
excessive generic types                    unnecessary factories
unnecessary classes                        needless dependency injection
speculative flexibility                    duplicated helpers
arbitrary fallbacks that hide bugs         architecture diagrams in source files
```

Prefer code that reads as:

```text
quiet
clear
predictable
purposeful
boring in the best way
```

A new developer should be able to follow the execution path without decoding a framework.

### 39.11 Clean up after yourself

Remove temporary scripts, scratch files, debug output, generated test data, and one-off helpers. Do not leave `test2.lua`, `temp.py`, `debug.json`, `scratch.md`, `try_this.lua`, or `new_new_fixed.lua` in the repository.

Before finishing, remove debugging debris: stray `print`, `warn`, debug parts, test buttons, temporary remotes, temporary GUI, hardcoded test user IDs, forced currency, forced rewards, and debug teleports — unless deliberately retained behind a proper dev-only mechanism.

### 39.12 Self-review before finishing

```text
Did I create files I don't need?
Did I introduce an abstraction used once?
Did I duplicate a system that already exists?
Did I touch unrelated code?
Did I add speculative functionality?
Did I add defensive code for impossible states?
Did I add unnecessary types or comments?
Could this be significantly simpler?
Did I create a second source of truth?
Did I leave temporary or debug files?
Does this fit the existing architecture?
```

Any yes means simplify before delivering.

---

## 40. Comments and Documentation

### Comments explain why, not what

Comment: unusual existence, non-obvious constraints, important invariants, security assumptions, engine quirks, difficult formulas, intentional tradeoffs, temporary limitations with a real reason.

Do not comment: every variable, every require, obvious loops, obvious conditionals, obvious property assignments, every function, or anything readable code already says.

```luau
-- Bad
-- Check if player has enough coins
if coins >= price then
    -- Remove price from coins
    coins -= price
end

-- Good
-- Price resolves server-side; the client's quoted price is display-only.
local price = ShopRegistry[itemId].Price

-- Good
-- Roblox may fire this twice during character replacement; guard by character id.

-- Good
-- Deferred one frame so the imported layout has resolved AbsoluteSize.
task.defer(...)

-- Good
-- Keep the anchor parented here so StreamingEnabled cannot unload it mid-round.
```

### What to avoid

**No banner comments.** If a file needs a dozen `-----` separators to be navigable, split the file.

**No file-header essays.** A simple service does not need a `--[[ Responsibilities / Architecture / Data Flow / Dependencies ]]` block. One line, if any:

```luau
-- Owns authoritative inventory mutations and their replication.
```

Architectural explanation belongs in `ARCHITECTURE.md`.

**No change history in comments.** Git has that.

**No vague TODOs.** `-- TODO improve this` is noise. `-- TODO: replace this distance check once server-authoritative raycasts land (#412)` is a task.

**Keep comments true.** A wrong comment is worse than none. When code changes, update or delete the comment.

### The justification test

> A comment is justified when a competent Roblox developer joining later would gain information that is not obvious from the code.

### Documentation

Permanent documentation covers **stable knowledge**: ownership, boundaries, public contracts, non-obvious decisions, project conventions, workflows, operational information, and architectural reasoning.

**Do not generate a Markdown report every time a feature changes.** Do not write an architecture document for a small implementation. Do not create investigation write-ups for ordinary debugging unless asked.

Maintain:

```text
CLAUDE.md              concise always-on rules (~150 lines)
.claude/rules/*.md     path-scoped rules
ARCHITECTURE.md        this game's actual architecture
docs/UI_ARCHITECTURE.md   for UI-heavy projects: layers, components, routes,
                          modal rules, import conventions, tokens, input, responsive
docs/ASSET_MANIFEST.md    for asset-heavy projects
```

Update them when architecture materially changes — not on every commit.

### CLAUDE.md must stay small

Do not copy this standard into `CLAUDE.md`. Keep it to always-on essentials:

```text
filesystem is the source of truth for Rojo-managed code
Rojo + Git + VS Code; no Knit; custom ModuleScript architecture
server authority for anything of value
inspect before editing; extend, don't duplicate
smallest change that fits the architecture; no unsolicited refactors
concise comments explaining why
Figma UI is the View; logic lives in .luau
verify before claiming success
```

Path-scoped rules keep the rest out of every context window:

```text
.claude/rules/
├── luau-code.md              paths: src/**/*.luau
├── ui.md                     paths: src/client/ui/**
├── networking-security.md    paths: src/server/security/**, src/shared/network/**
├── persistence.md            paths: src/server/persistence/**
└── testing.md                paths: tests/**
```

---

## 41. Verification and Definition of Done

**Writing code is not evidence that code works.** Never report something fixed because it looks plausible.

### The verification menu

Choose from it in proportion to the change:

```text
StyLua format check          Selene lint
luau-lsp type analysis       unit tests
rojo build validation        targeted Studio inspection (MCP)
playtest                     runtime log inspection
visual comparison to a reference   Git diff review
```

### Proportionality

| Change | Minimum verification |
|---|---|
| Tune a config number | Read the diff; confirm it is the intended value and units |
| Fix a UI binding | Playtest the screen; confirm the interaction |
| Implement UI from a Figma reference | Playtest + visual comparison to the reference + 2–3 aspect ratios |
| Add a gameplay system | Types + tests for the deterministic parts + playtest |
| Touch economy, persistence, security, or monetization | Types + tests + playtest + adversarial reasoning about the failure modes + diff review |

> Tiny change ≠ enormous QA ceremony.
> Critical economy/security/persistence change ≠ "looks fine."

### Always review the diff

Before declaring substantial work done, read the diff for: accidental unrelated edits, leftover debug code, forgotten prints, duplicated logic, unused imports, accidental files, excessive comments, and unexpected architectural changes.

### Report honestly

If tests fail, say so and show the output. If a step was skipped, say which and why. If part of the scope was blocked, finish everything else and state exactly what was left out. When something is done and verified, say so plainly.

---

## 42. Project Startup

For a new serious Roblox game, in order:

```text
1.  git init; create the repository
2.  rokit.toml — pin rojo, stylua, selene, luau-lsp
3.  default.project.json — establish the container mapping
4.  src/{bootstrap,server,client,shared} — the skeleton only
5.  .luaurc, stylua.toml, selene.toml, .gitignore
6.  CLAUDE.md — concise, always-on
7.  .claude/rules/ — path-scoped, where useful
8.  ARCHITECTURE.md — start it now, grow it continuously
9.  Define the actual gameplay domains for THIS game
10. Define server / client / shared boundaries
11. Define DataModel organization
12. Define the first network contracts
13. Define persistence ownership and the schema (with a version field from v1)
14. Define UI architecture and the Figma workflow
15. Define asset locations
16. Define security boundaries — what is authoritative
17. Define map and streaming strategy
18. Record performance risks and a target device
19. Then implement the first feature
```

**Create only what the game needs.** No empty `Trading/` folder. No `LiveOps/` for a prototype. No `VehicleRegistry` for a game without vehicles.

Steps 9–18 are mostly writing in `ARCHITECTURE.md`, and they take under an hour. They save weeks.

---

## 43. Non-Negotiables

Unless explicitly overridden by the project owner:

```text
FILESYSTEM SOURCE IS AUTHORITATIVE FOR ROJO-MANAGED CODE.
NEVER EDIT ROJO-MANAGED SCRIPT SOURCE THROUGH STUDIO MCP.
ROJO AND VS CODE FIRST. STUDIO MCP ONLY WHEN STUDIO IS GENUINELY REQUIRED.

USE CLAUDE CODE + VS CODE + GIT + ROJO. NO KNIT. NO ARCHITECTURE-OWNING FRAMEWORK.
CUSTOM MODULESCRIPT ARCHITECTURE, FEW BOOTSTRAPS, MANY FOCUSED MODULES.

THE CLIENT EXPRESSES INTENT. THE SERVER DETERMINES TRUTH.
VALIDATE EVERY CLIENT REQUEST SERVER-SIDE. RATE-LIMIT EXPLOITABLE REMOTES.
THE SERVER OWNS CURRENCY, INVENTORY, PROGRESSION, REWARDS, DAMAGE, AND TRADES.
ECONOMIC MUTATIONS ARE ATOMIC. RECEIPTS ARE IDEMPOTENT. PROFILES ARE SESSION-LOCKED.
FILTER ALL USER-GENERATED TEXT.
OBFUSCATION IS NOT SECURITY.

ONE OWNER PER RESPONSIBILITY. NO SECOND SOURCE OF TRUTH.
DEPENDENCIES POINT TOWARD SHARED. NO CIRCULAR REQUIRES.
TAGS AND COMPONENTS INSTEAD OF SCRIPTS IN HUNDREDS OF OBJECTS.
WORKSPACE IS THE LIVE WORLD, NOT TEMPLATE STORAGE.
SERVER-ONLY CONTENT STAYS IN SERVERSTORAGE.
REPLICATE ONLY WHAT THE CLIENT NEEDS.
BUILD LARGE WORLDS STREAMING-AWARE FROM DAY ONE.

FIGMA UI IS THE VIEW; LOGIC LIVES IN .LUAU CONTROLLERS.
DO NOT REBUILD GOOD IMPORTED UI IN CODE.
DO NOT INVENT A DESIGN LANGUAGE WHEN THE GAME HAS ONE.
COMPARE UI TO ITS REFERENCE BEFORE CLAIMING IT MATCHES.
RESPONSIVE AND INPUT BEHAVIOR ARE PART OF IMPLEMENTATION, NOT CLEANUP.

COSMETIC WORK IS CLIENT-SIDE. COSMETICS NEVER DECIDE AUTHORITATIVE OUTCOMES.
PROFILE BEFORE OPTIMIZING. NO ARBITRARY UNIVERSAL PERFORMANCE NUMBERS.
EVERYTHING THAT CONNECTS, DISCONNECTS.

COMMENT WHY, NOT WHAT. KEEP COMMENTS SHORT AND HUMAN.
DO NOT OVERENGINEER. DO NOT CREATE FILES OR ABSTRACTIONS WITHOUT A REAL REASON.
DO NOT REFACTOR UNRELATED WORKING CODE. DO NOT LEAVE DEBUGGING DEBRIS.
VERIFY IMPORTANT WORK BEFORE CLAIMING SUCCESS.

MAKE THE SMALLEST CLEAN CHANGE THAT FITS THE EXISTING ARCHITECTURE.
```

---

## 44. Closing Principle

> **Build for scale without pretending scale already exists.**

Claude's job is not to produce the most code possible. Claude's job is to:

```text
understand the existing game
→ identify the correct owner
→ make the smallest robust change
→ preserve the architecture
→ verify the important boundaries
→ leave unrelated working code alone
```

The ideal codebase feels boring in the best way:

```text
easy to navigate      easy to search
easy to extend        easy to review
easy to debug         hard to exploit
hard to accidentally break
```

A giant Roblox game should not require giant confusion.
