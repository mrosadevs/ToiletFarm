# STUDIO GAME → ROJO + VS CODE MIGRATION

> Paste this at the start of a session when converting an **existing Roblox game that was built inside Studio** to a Rojo + VS Code + Git workflow, and then bringing it up to the production standard.
> For a brand-new game, use `NEW_GAME_KICKOFF.md` instead.

---

## Your role

You are migrating a working, possibly live game. The game already works. **Your first job is to not break it.**

`ROBLOX_GAME_STANDARD_FINAL.md` is the target standard. Read sections as needed; do not load it wholesale.

Two rules govern this entire session:

> **1. Migration is not a rewrite.**
> **2. Achieve parity before improving anything.**

The game must behave identically after migration. Improvements come afterward, in separate, reviewable phases, in priority order — and only the ones I approve.

---

## How you work in this session (read before anything else)

> **Rojo and VS Code first. Studio MCP only when Studio is genuinely required.**

The filesystem is the source of truth for all Rojo-managed code. Your default working
surface is `.luau` files in the repository, edited locally, synced by Rojo, tracked by Git.

**Before every Studio MCP call, ask:**

```text
Can I answer this by searching the repository?      → do that instead
Can I answer this by reading a file?                → do that instead
Can I make this change by editing a file?           → do that instead
Does this genuinely need the live DataModel,
  a Studio-authored instance, or a running game?    → now MCP is correct
```

**Never edit the source of a Rojo-managed script through Studio MCP.** That creates a
second version of the file, and one of the two is silently discarded on the next sync.

MCP is correct for: DataModel and UI hierarchy inspection, Figma import review,
instance/property/tag/attribute work, map objects, Lighting, VFX, runtime state,
playtests, screen capture, and Studio-specific debugging.

MCP is wrong for: reading logic you could read from a file, making changes you could
make in a file, and bulk-dumping the DataModel. Keep every inspection scoped to one
subtree — never enumerate `Workspace`, `ReplicatedStorage`, or `ServerScriptService`
wholesale.

**One migration-specific exception:** until Phase 6 parity is confirmed, the code still
lives in Studio, so MCP reading is expected and correct during Phases 1 and 3. From the
Phase 5 cutover onward, the filesystem is authoritative and the rule above applies in
full — including to me. Tell me if I ask you to edit a script in Studio after that point.

---

# PHASE 0 — SAFETY

**Do not skip this. Do not start Phase 1 until it is done.**

1. **Back up the place file.** Have me do `File → Save to File As…` and save `<GameName>_pre-migration_<date>.rbxl` somewhere outside the repo. Confirm the file exists before continuing.
2. **Check Team Create.** If Team Create is on, ask me whether anyone else is editing. Rojo syncing into a live Team Create session while someone else edits will produce conflicts and lost work. Coordinate or turn it off.
3. **Confirm this is not the live production place** we're experimenting in — or if it is, that we're working on a copy.
4. **Confirm Studio MCP is connected** and note whether you can read the tree.

Report the state of all four before proceeding.

---

# PHASE 1 — AUDIT

**Understand what exists before touching it.** Do not run a converter yet.

Use Studio MCP with **targeted** queries — do not dump the entire DataModel (see standard §38). Produce a written inventory:

### 1.1 Script census

For each of these containers, list scripts by path, type, and approximate line count:

```text
ServerScriptService
ServerStorage
ReplicatedStorage
ReplicatedFirst
StarterPlayer/StarterPlayerScripts
StarterPlayer/StarterCharacterScripts
StarterGui
Workspace              ← scripts inside world objects; count them, this matters
Lighting / SoundService / anywhere else scripts are hiding
```

Flag specifically:
- **Scripts inside Workspace objects** (doors, NPCs, collectibles, spawners). These are the hard case — see §3.4.
- **Scripts inside StarterGui / UI hierarchies.** Also a hard case.
- **Disabled scripts** and obviously dead code.
- **Duplicated logic** — the same handler copy-pasted across objects.

### 1.2 Non-code inventory

What is Studio-authored and must **not** become filesystem source:

```text
Terrain
Map geometry
UI hierarchies (especially anything Figma-imported)
Particle/VFX assemblies
Lighting and post-processing setup
Models, meshes, decals
Attributes and CollectionService tags already in use
```

### 1.3 Risk audit

While you're reading, note but **do not fix yet**:

```text
Client-authoritative logic (client tells server a value the server should own)
Direct DataStoreService calls scattered across modules
Remotes with no validation
Anything that grants currency, items, or progression without a server check
while true do loops and per-frame work that shouldn't be per-frame
Connections that are never disconnected
Hardcoded asset IDs repeated across files
Giant if/elseif content chains
```

Deliver this as a **short prioritized list**, not a report document. Three severity buckets: *exploitable now*, *structural debt*, *cosmetic*.

**Then stop and show me the audit before proceeding.**

---

# PHASE 2 — DECIDE THE BOUNDARY

Rojo owns code. Studio keeps authored content. Write the split down before extracting anything.

| Rojo owns (filesystem, in Git) | Studio keeps (in the place, or committed as `.rbxmx`) |
|---|---|
| All ModuleScripts, Scripts, LocalScripts | Terrain |
| Configuration and content tables | Map geometry |
| Network definitions | Figma-imported UI hierarchies |
| Types | VFX assemblies |
| Simple structural instances (`.model.json`) | Lighting setup |
| Small versioned prefabs (`.rbxmx`) | Meshes, decals, large models |

**Anything Studio-authored that you want in Git** gets exported to `assets/` as `.rbxmx` (XML — diffable) or `.rbxm` (binary — for large opaque assets) and referenced by `$path` in the project file.

Confirm this split with me before extracting.

---

# PHASE 3 — EXTRACT

Choose **one** approach and tell me which and why:

### Option A — Studio MCP extraction (recommended when MCP is connected)

Read each script's source through MCP and write it to the correct filesystem path, one at a time, preserving structure. Slower, but you control the resulting tree and can name things sensibly as you go.

Best when: the script count is manageable (under ~150), or the existing hierarchy is messy enough that a mechanical conversion would produce a mess.

### Option B — Place-file conversion

Save as `.rbxlx`, then run a converter (`rbxlx-to-rojo` from the rojo-rbx org, or a current equivalent) against it and clean up the output.

Best when: there are hundreds of scripts and the existing hierarchy is already reasonable.

**Caveat:** these tools convert the *whole place*, including things that should stay Studio-authored. Expect to delete a large fraction of the output. Verify the tool is current before relying on it.

### Option C — Hybrid (usual answer for a large messy place)

Convert mechanically to get the source out fast, then restructure the *files* by hand into the target tree while the code itself stays byte-identical.

### Extraction rules — regardless of option

- **Preserve source exactly.** Do not fix bugs, reformat, rename variables, or "clean up" during extraction. Byte-identical where possible. A migration diff must be reviewable as *pure movement*.
- **Use `.luau`**, with `.server.luau` / `.client.luau` for executable scripts and plain `.luau` for ModuleScripts.
- **Preserve require paths.** If moving a module breaks a `require`, either keep the location or fix the require — and note every require you changed.
- **`init.luau`** for a ModuleScript that had children.
- **Do not delete anything from the place yet.**

---

# PHASE 4 — PROJECT FILE

Write `default.project.json` to reproduce the **existing** hierarchy, not the ideal one.

```json
{
  "name": "<GameName>",
  "tree": {
    "$className": "DataModel",
    "ServerScriptService": { "$path": "src/ServerScriptService" },
    "ReplicatedStorage":   { "$path": "src/ReplicatedStorage" },
    "StarterPlayer": {
      "StarterPlayerScripts": { "$path": "src/StarterPlayerScripts" }
    }
  }
}
```

Two critical details:

1. **Map only the containers Rojo owns.** Do not map `Workspace` or `StarterGui` if Studio still owns their contents — Rojo will replace what it manages at that path.
2. **`$ignoreUnknownInstances` — get this right or you will delete map work.**

   - `true` → Rojo **leaves alone** instances it doesn't manage at that node. Use this wherever Studio-authored content lives alongside Rojo-managed content.
   - `false` → Rojo **removes** instances it doesn't manage at that node. Use this only where Rojo owns the node completely.

   Rojo defaults it to `false` on nodes that specify `$path`, and `true` on nodes that don't. That default is the dangerous one: pointing a `$path` at a container that also holds Studio-authored models means Rojo will delete those models on sync. Set it explicitly on every mapped container rather than relying on the default, and verify against a backup before the first sync.

Also set up:

```bash
rokit.toml     # pin rojo, stylua, selene, luau-lsp
.gitignore     # *.rbxl, *.rbxlx, sourcemap.json, build/, .DS_Store
.luaurc        # start in nonstrict; strict comes later, per-file
```

**Start `.luaurc` in `nonstrict`.** Flipping a legacy codebase to strict on day one produces thousands of errors and tells you nothing. Add `--!strict` per file as you touch it.

---

# PHASE 5 — THE DUPLICATE-EXECUTION HAZARD

**Read this carefully. This is where migrations break games.**

Once Rojo syncs, any script that exists **both** in the filesystem **and** still in the place at an unmapped location will run **twice**. Two servers of the same logic, two sets of connections, double rewards, double damage.

Rojo replaces what it manages at a mapped path. It does **not** touch anything outside those paths.

### The safe cutover

1. Connect Rojo and let it sync into the place.
2. Walk the mapped containers and **delete every original script Rojo now provides.** Verify by count: the number of scripts under each mapped container should match the number of files under its `$path`.
3. Walk the **unmapped** containers and confirm nothing there duplicates migrated logic.
4. Playtest and watch Output for anything firing twice — duplicate prints, doubled currency, doubled spawns.

Do this container by container, verifying each before moving to the next. Do not sync everything at once and hope.

---

# PHASE 6 — PARITY VERIFICATION

**No improvements until parity is proven.**

```bash
rojo build default.project.json -o /tmp/migrated.rbxl   # must build
```

Then, with me:

1. Connect Rojo in Studio, confirm the tree matches the pre-migration tree.
2. Playtest the **core loop end to end** — the actual main gameplay path, not just "it loads."
3. Exercise every risky path from the Phase 1 audit: purchases, saves, rewards, spawns, UI screens.
4. **Rejoin** and confirm persistent data loaded correctly. Then rejoin again. Data loss shows up on the second join.
5. Check Output for new errors and for anything happening twice.

Compare against the pre-migration backup if anything is ambiguous.

**Commit only after parity is confirmed:**

```bash
git add -A
git commit -m "Migrate <GameName> to Rojo: extract scripts to filesystem, no behavior changes"
```

That commit should contain **zero intentional behavior changes.** If it doesn't, split it.

---

# PHASE 7 — HARD CASES

These don't migrate cleanly. Handle them deliberately, each as its own change.

### 7.1 Scripts inside Workspace objects

A `Script` inside each of two hundred doors cannot be Rojo-managed sensibly, and it's also the wrong architecture (standard §21).

The correct fix is tags + one component module:

```text
Before:  200 doors, each with a Script
After:   200 doors tagged "Door" with Attributes (DoorId, Locked, RequiredLevel)
         + one DoorComponent.luau in the filesystem
```

**But this is a refactor, not a migration.** Options, in order of preference:

- **Leave them in place for now.** Note them in `ARCHITECTURE.md` as debt. The game keeps working.
- **Convert one category at a time**, as its own commit, with its own playtest. Start with the category that has the most instances or the most duplication.
- Never convert all of them in one change.

### 7.2 Scripts inside StarterGui / UI hierarchies

Same shape of problem. Move the *logic* into `src/client/ui/` controllers that bind to the existing (Studio- or Figma-authored) hierarchy. **Do not rebuild the UI in code** — the visual hierarchy is the View and it already works (standard §26).

If the UI came from Figma, export the hierarchy to `assets/replicated/UI/*.rbxmx` so it's versioned, and keep the controllers in the filesystem.

### 7.3 Scripts that depend on their own location

Anything using `script.Parent` to reach a sibling instance breaks when the script moves. Find these during extraction, and either preserve the relationship (via `.model.json` / `.rbxmx`) or convert to an explicit lookup. Note every one you change.

### 7.4 Studio-side editing after migration

Once code lives in the filesystem, **editing script source in Studio silently creates a second version that Rojo will overwrite.** Tell me this explicitly, and if there's a team, make sure everyone knows before the first sync.

---

# PHASE 8 — REMEDIATION, IN PRIORITY ORDER

Now, and only now, improve the codebase — **one phase at a time, each committed separately, each playtested.**

Work down the Phase 1 audit in this order. Do not skip ahead to the satisfying refactors.

### Tier 1 — Exploitable now (do these first)

```text
Client-authoritative values the server should own
Remotes with no payload validation or rate limiting
Currency, item, or progression grants the server doesn't verify
Non-atomic economic mutations (currency removed in one place, item granted in another)
Direct DataStore writes scattered across modules
Missing session locking if there's trading or an economy
Non-idempotent ProcessReceipt
Unfiltered user-generated text
```

Reference: standard §18 and §19. These fix real losses. Do them even if they're less fun than restructuring folders.

### Tier 2 — Structural debt

```text
Consolidate duplicate systems into one owner
Introduce a central RemoteGuard rather than per-handler validation
Move Workspace-object scripts to tags + components (§7.1, incrementally)
Extract giant if/elseif content chains into registries
Centralize scattered asset IDs
Fix connection leaks and missing player cleanup
Replace per-frame loops that should be event-driven
```

### Tier 3 — Structure and polish

```text
Reorganize the file tree toward the standard's layout — ONLY if the current one is
  genuinely causing navigation problems. A coherent existing structure stays.
Introduce types at boundaries (public APIs, network payloads, persistent schemas)
Add --!strict per file as you touch it
Add StyLua + Selene to CI
Add tests for the deterministic high-risk logic (economy math, loot rolls, validators)
Design tokens, if the UI count justifies them
```

### Rules for the whole of Phase 8

- **One concern per commit.** Never mix a security fix with a folder reorganization.
- **Playtest after each.** A migration that ends with a broken game is a failed migration regardless of how clean the code looks.
- **Ask before restructuring.** Moving files is high-churn and low-value compared to Tier 1. Get my approval before any large reorganization.
- **Do not rewrite working systems** because a different architecture would be nicer. Standard §39.2.
- **Do not add types, comments, or formatting to files you aren't otherwise changing.**

---

# PHASE 9 — DOCUMENT THE RESULT

Write `ARCHITECTURE.md` describing **what the game actually is now**, not what it should become:

```markdown
# <GameName> Architecture

## Migration status
Migrated to Rojo on <date>. Pre-migration backup: <path>
Rojo owns: <containers>
Studio owns: <terrain / map / UI / VFX>

## Domains
<the domains that actually exist, with their real module paths>

## Trust boundaries
Server-authoritative: <list>
Known client-authoritative gaps: <list — this is honest debt, keep it visible>

## Persistence
<current owner, schema, whether session locking exists>

## Known debt
| Item | Tier | Where | Notes |
|---|---|---|---|
<carry the unfixed Phase 1 audit items here so they don't get lost>
```

Then a concise `CLAUDE.md` (~150 lines, always-on rules only — see `NEW_GAME_KICKOFF.md` Step 5) with one addition specific to a migrated project:

```text
- This project was migrated from Studio. Some legacy patterns remain and are
  tracked in ARCHITECTURE.md under Known debt. Do not opportunistically "fix"
  them mid-task — they get their own changes.
```

---

## Things I do not want in this session

- Any behavior change inside the migration commit
- A full rewrite of working systems
- A repository-wide reformat or rename before parity is proven
- Converting every Workspace script to components in one change
- Rebuilding working UI in code
- A framework being introduced during migration
- Adding types or `--!strict` across files you aren't otherwise touching
- A large Markdown migration report — `ARCHITECTURE.md` is the deliverable
- Claiming migration success without an actual playtest and a rejoin data check

---

## Definition of done

```text
[ ] Pre-migration backup exists and I confirmed it
[ ] Audit delivered and reviewed before extraction
[ ] Rojo/Studio ownership split agreed
[ ] Source extracted with no intentional behavior changes
[ ] default.project.json reproduces the existing hierarchy
[ ] Every duplicate original script removed from mapped containers, verified by count
[ ] rojo build succeeds
[ ] Core loop playtested end to end
[ ] Persistent data verified across two rejoins
[ ] No doubled behavior in Output
[ ] Migration committed as a pure-movement diff
[ ] Tier 1 security items either fixed (separate commits) or recorded as debt
[ ] ARCHITECTURE.md reflects reality, including the debt
[ ] I know not to edit script source in Studio anymore
```
