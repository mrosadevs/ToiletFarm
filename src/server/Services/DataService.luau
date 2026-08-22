--!strict
-- DataService — owns the player profile: load, autosave, and the single mutation entry point.
-- Everything else reads through DataService.get(player) and writes through DataService.update().

local Players = game:GetService("Players")
local DataStoreService = game:GetService("DataStoreService")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.ToiletConfig)
local Net = require(Shared.Net)

local STORE_NAME = "ToiletFarm_v1"
local AUTOSAVE = 90

-- Session locking. A profile records the JobId that owns it plus a heartbeat.
-- Another server may only take the profile once that heartbeat has gone stale,
-- which is what stops two servers from round-tripping the same save and
-- rolling each other's progress back.
-- Comfortably longer than one autosave cycle, so a live server that is merely slow
-- is never mistaken for a dead one. Only a hard crash leaves a lock to time out;
-- an orderly shutdown releases it through the final save.
local LOCK_STALE = 240       -- seconds before an unrefreshed lock may be taken
local LOAD_ATTEMPTS = 6      -- how many times to wait for a live lock to release
local LOAD_RETRY_WAIT = 5

local store = DataStoreService:GetDataStore(STORE_NAME)
local JOB_ID = game.JobId ~= "" and game.JobId or ("studio_" .. tostring(os.time()))

-- In Studio with "Enable Studio Access to API Services" off, DataStore calls throw.
-- Fall back to an in-memory profile there so the game is still playable, but never
-- do this in a live server, where a failed read means real progress is at risk.
local studioNoApi = false
local function isApiDisabled(err: string?): boolean
	return RunService:IsStudio() and tostring(err):find("Studio access to APIs") ~= nil
end
local StateChanged = Net.event(Net.NAMES.StateChanged)

local DataService = {}
local profiles: { [Player]: any } = {}
local loading: { [Player]: boolean } = {}

function DataService.default()
	local upgrades = {}
	for key in pairs(Config.UPGRADES) do upgrades[key] = 0 end
	local perks = {}
	for _, p in ipairs(Config.TOKEN_PERKS) do perks[p.id] = 0 end
	return {
		cash          = 10,
		-- `poops` is the total VALUE carried (what the basket shows, e.g. 162.21K).
		-- `poopItems` is how many physical poops that is, and it's the count the
		-- Septic Capacity cap applies to — one T30 poop is worth 10Qa, so capping
		-- on value would mean the tank fills on a single drop.
		poops         = 0,
		poopItems     = 0,
		rebirths      = 0,
		tokens        = 0,
		buyTier       = 1,      -- what tier the Buy pads sell; raised at the Upgrade pad

		toilets       = {},     -- { {tier=n, mut="None", slot=n}, ... }
		processing    = 0,      -- selling-rate level, wiped on rebirth
		-- Cash that finished processing and is waiting on the Collect Cash pad, plus
		-- the selling queue still draining. EconomyService owns these at runtime and
		-- folds them back in through DataService.onSerialize before every save.
		pendingCash   = 0,
		queuePoops    = 0,
		queueCash     = 0,
		upgrades      = upgrades,
		perks         = perks,
		discovered    = {},     -- ["T01_PorcelainStarter"] = true
		luckyInv      = {},     -- { {id="Basic", uid="..."} }
		codes         = {},
		-- PurchaseIds already granted, so a retried receipt is never paid out twice.
		-- Trimmed to the newest RECEIPT_HISTORY entries; Roblox stops retrying long
		-- before a player could push that many purchases through.
		receipts      = {},
		-- AutoPoop/AutoCash default ON. They do nothing without the matching gamepass,
		-- so the toggle is an opt-out for owners rather than a second thing to find
		-- before a purchase starts working.
		settings      = { Music = 0.5, Sfx = 0.8, MuteToilets = false, AutoPoop = true, AutoCash = true },
		stats         = { playtime = 0, totalDeposited = 0, bestCash = 0 },
		tutorial      = 1,      -- current step index; 0 once finished
		-- os.time() of the last free-money chest claim. Persisted because an
		-- uptime-based cooldown resets every time the player changes server.
		lastChestAt   = 0,
		-- os.time() of the last group-pad payout, persisted for the same reason
		lastGroupRewardAt = 0,
		lastLogout    = 0,
		-- Two rates, because offline pay has to arrive in both currencies: the value
		-- the basket banks and the item count the basket displays. Crediting only the
		-- value made Claim look like it did nothing at all.
		rateAtLogout  = 0,
		itemRateAtLogout = 0,
		version       = 1,
	}
end

-- SetAsync serialises whatever it is handed at the moment it actually runs, and it
-- yields. A shallow table.clone shares every nested table with the live profile, so
-- a mutation landing mid-save writes a torn mixture of two states. Copy deeply.
local function deepCopy(v: any): any
	if type(v) ~= "table" then return v end
	local out = {}
	for k, inner in pairs(v) do out[k] = deepCopy(inner) end
	return out
end

-- fill in anything a newer version added without clobbering saved values
local function reconcile(saved, template)
	for k, v in pairs(template) do
		if saved[k] == nil then
			saved[k] = (type(v) == "table") and table.clone(v) or v
		elseif type(v) == "table" and type(saved[k]) == "table" then
			reconcile(saved[k], v)
		end
	end
	return saved
end

-- Fix-ups a saved profile needs that `reconcile` cannot do, because reconcile only
-- fills in keys that are MISSING and these are keys with the wrong value saved.
-- `schema` is deliberately NOT in the default template. reconcile() fills in every
-- key the template has and missing keys are exactly how an un-migrated profile is
-- recognised, so putting it there stamped every old save as already migrated before
-- this function ever saw it.
local function migrate(p)
	local from = tonumber(p.schema) or 1
	if from < 2 then
		-- Auto Collect was gated behind a setting that defaulted to false, so the pass
		-- did nothing at all until the buyer found the switch. Anyone who saved before
		-- this has `false` on disk; nobody can have meant it, because the toggle had no
		-- effect to opt out of.
		p.settings.AutoPoop = true
		p.settings.AutoCash = true
	end
	p.schema = 2
	return p
end

local function key(player: Player): string
	return "p_" .. player.UserId
end

function DataService.get(player: Player)
	return profiles[player]
end

function DataService.isLoaded(player: Player): boolean
	return profiles[player] ~= nil
end

-- Push state to the owning client. `partial` lets a hot path send just what changed.
function DataService.push(player: Player, partial: {[string]: any}?)
	local p = profiles[player]
	if not p then return end
	if partial then
		StateChanged:FireClient(player, partial)
	else
		StateChanged:FireClient(player, {
			cash = p.cash, poops = p.poops, poopItems = p.poopItems, rebirths = p.rebirths,
			tokens = p.tokens, processing = p.processing, buyTier = p.buyTier,
			toilets = p.toilets, upgrades = p.upgrades, perks = p.perks,
			discovered = p.discovered, luckyInv = p.luckyInv, settings = p.settings,
			stats = p.stats, tutorial = p.tutorial,
			carryCap = DataService.carryCap(player),
			slots = DataService.slots(player),
			maxTier = Config.maxBuyableTier(p.rebirths),
			multiplier = DataService.incomeMultiplier(player),
			-- derived on the server like every other field here; the HUD storefronts
			-- need to know what is already owned so they can stop advertising it
			passes = DataService.ownedPasses(player),
		})
	end
end

-- mutate + push in one call so nothing can change state and forget to replicate
function DataService.update(player: Player, fn: (any) -> ({[string]: any}?))
	local p = profiles[player]
	if not p then return end
	local partial = fn(p)
	DataService.push(player, partial)
end

-- ── derived values ──────────────────────────────────────────────────────────
function DataService.hasPass(player: Player, passName: string): boolean
	local Passes = require(script.Parent.PassService)
	return Passes.has(player, passName)
end

-- Which passes this player owns. PassService.has caches per user, so this stays a
-- table lookup after the first call rather than a web call per push.
function DataService.ownedPasses(player: Player): { [string]: boolean }
	local Passes = require(script.Parent.PassService)
	local owned = {}
	for name, id in pairs(Passes.PASSES) do
		if id ~= 0 then owned[name] = Passes.has(player, name) end
	end
	return owned
end

-- how many individual poops the player can hold before toilets stop littering
function DataService.carryCap(player: Player): number
	local p = profiles[player]
	if not p then return Config.BASE_CARRY end
	return Config.carryCap(p.upgrades.SepticCapacity or 0)
end

function DataService.slots(player: Player): number
	local p = profiles[player]
	if not p then return 8 end
	return Config.plotSlots(p.rebirths, p.upgrades.PlotSlots or 0, p.perks.ExtraPlot or 0)
end

-- every income multiplier in one place, so the stacking order in the design doc is enforced once
function DataService.incomeMultiplier(player: Player): number
	local p = profiles[player]
	if not p then return 1 end
	local m = Config.rebirthMultiplier(p.rebirths)
	m *= 1 + 0.05 * (p.perks.RichDiet or 0)
	if DataService.hasPass(player, "DoublePoop") then m *= 2 end
	-- full toilet Index is a permanent +25%
	local found = 0
	for t = 1, Config.MAX_TIER do
		if p.discovered[Config.assetId(t)] then found += 1 end
	end
	if found >= Config.MAX_TIER then m *= (1 + Config.INDEX_ALL_TOILETS_BONUS) end
	return m
end

-- Cash-side multipliers only. Poop-side ones (rebirth, perks, DoublePoop) are
-- already baked into p.poops as poops are earned, so applying them again here
-- would double-count them.
function DataService.cashMultiplier(player: Player): number
	local p = profiles[player]
	if not p then return 1 end
	local m = 1
	if DataService.hasPass(player, "DoubleCash") then m *= 2 end
	return m
end

-- live poop/sec across every toilet the player owns, before the Flush Meter
function DataService.poopRate(player: Player): number
	local p = profiles[player]
	if not p then return 0 end
	local speed = 1 - 0.03 * (p.upgrades.FlushSpeed or 0)
	local valueUp = 1 + 0.10 * (p.upgrades.PoopValue or 0)
	local mult = DataService.incomeMultiplier(player)
	local total = 0
	for _, t in ipairs(p.toilets) do
		local interval = Config.dropInterval(t.tier) * speed
		local value = Config.poopValue(t.tier) * valueUp * (Config.MUTATIONS[t.mut] or 1) * mult
		total += value / interval
	end
	return total
end

-- How many individual poops the farm drops per second. poopRate is the same sum
-- weighted by value; the offline payout needs both, since one is what the basket
-- banks and the other is what the basket counts.
function DataService.poopItemRate(player: Player): number
	local p = profiles[player]
	if not p then return 0 end
	local speed = 1 - 0.03 * (p.upgrades.FlushSpeed or 0)
	local total = 0
	for _, t in ipairs(p.toilets) do
		-- weighted by what each drop COUNTS as, so a night offline on Tier 8 toilets
		-- banks the same basket figure as standing there collecting them
		total += Config.poopCount(t.tier) / (Config.dropInterval(t.tier) * speed)
	end
	return total
end

-- The same rate with the PURCHASED multipliers taken back out. The buy price is
-- keyed off this: DoublePoop doubles poopRate, so pricing off the raw figure would
-- charge a player double for every toilet because they bought a gamepass. Rebirth
-- and perk multipliers stay in -- those are earned, and a tycoon is supposed to get
-- dearer as you rebirth into more income.
function DataService.poopRateBase(player: Player): number
	local rate = DataService.poopRate(player)
	if DataService.hasPass(player, "DoublePoop") then rate /= 2 end
	return rate
end

-- ── global leaderboards ─────────────────────────────────────────────────
-- An OrderedDataStore is the only way to get a cross-server top N, and this module
-- is the only one allowed near DataStoreService, so both halves live here and
-- LeaderboardService merely renders what it is handed.
local BOARD_STORES = {
	Networth   = "TF_Board_Networth_v1",
	Toilets    = "TF_Board_Toilets_v1",
	Playtime   = "TF_Board_Playtime_v1",
}

-- An OrderedDataStore value must be a signed 64-bit integer, and late-game cash in
-- this game runs past that without effort. Anything above the ceiling ranks at the
-- ceiling, which costs nothing real: they are already top of the board.
local ORDERED_MAX = 9e15

local orderedStores: { [string]: OrderedDataStore } = {}
local function orderedStore(board: string): OrderedDataStore?
	if not BOARD_STORES[board] then return nil end
	local existing = orderedStores[board]
	if existing then return existing end
	local ok, s = pcall(function()
		return DataStoreService:GetOrderedDataStore(BOARD_STORES[board])
	end)
	if not ok then return nil end
	orderedStores[board] = s
	return s
end

local function boardValue(board: string, p): number
	if board == "Networth" then
		return p.cash or 0
	elseif board == "Playtime" then
		return (p.stats and p.stats.playtime) or 0
	end
	-- Toilets: merge-equivalents, the same figure the HUD calls "Total Toilets", so a
	-- farm of three Tier 4s does not rank below a farm of ten Tier 1s
	local n = 0
	for _, t in ipairs(p.toilets or {}) do
		n += Config.MERGE_COUNT ^ ((t.tier or 1) - 1)
	end
	return n
end

-- Called from the save path, so scores go out on the same cadence as the profile.
function DataService.publishScores(player: Player, p)
	if studioNoApi then return end
	for board in pairs(BOARD_STORES) do
		local s = orderedStore(board)
		if s then
			local value = math.floor(math.clamp(boardValue(board, p), 0, ORDERED_MAX))
			-- one player's board write must never take down a save
			local ok, err = pcall(function()
				s:SetAsync(tostring(player.UserId), value)
			end)
			if not ok then
				warn(("[DataService] leaderboard %s write failed: %s"):format(board, tostring(err)))
			end
		end
	end
end

-- userId -> name, resolved once. GetNameFromUserIdAsync is a web call and the same
-- handful of ids come back on every refresh.
local nameCache: { [number]: string } = {}
local function nameFor(userId: number): string
	local cached = nameCache[userId]
	if cached then return cached end
	local player = Players:GetPlayerByUserId(userId)
	if player then
		nameCache[userId] = player.Name
		return player.Name
	end
	local ok, name = pcall(function()
		return Players:GetNameFromUserIdAsync(userId)
	end)
	local resolved = (ok and type(name) == "string") and name or ("User " .. userId)
	nameCache[userId] = resolved
	return resolved
end

-- Top `count` for a board, best first. Returns an empty list rather than throwing if
-- the store is unreachable, so a leaderboard is never worse than blank.
function DataService.topScores(board: string, count: number): { { userId: number, name: string, value: number } }
	local out = {}
	local s = orderedStore(board)
	if not s or studioNoApi then return out end

	local ok, pages = pcall(function()
		return s:GetSortedAsync(false, math.clamp(count, 1, 100))
	end)
	if not ok then
		warn(("[DataService] leaderboard %s read failed: %s"):format(board, tostring(pages)))
		return out
	end

	local okPage, page = pcall(function() return pages:GetCurrentPage() end)
	if not okPage then return out end
	for _, entry in ipairs(page) do
		local userId = tonumber(entry.key)
		if userId then
			table.insert(out, { userId = userId, name = nameFor(userId), value = entry.value })
		end
	end
	return out
end

-- ── load / save ───────────────────────────────────────────────────────────
-- Every write goes through UpdateAsync so the read-modify-write is atomic against
-- other servers, and so a save can refuse to clobber a profile this server no
-- longer owns.
local function lockIsForeign(saved): boolean
	local lock = saved and saved.lock
	if type(lock) ~= "table" then return false end
	if lock.jobId == nil or lock.jobId == JOB_ID then return false end
	return (os.time() - (tonumber(lock.heartbeat) or 0)) < LOCK_STALE
end

local function loadProfile(player: Player): any
	loading[player] = true

	local data, lastErr
	local claimed = false

	for attempt = 1, LOAD_ATTEMPTS do
		local blocked = false
		local ok, err = pcall(function()
			local function claim(saved: any): (any, { number }?, any)
				if lockIsForeign(saved) then
					blocked = true
					return nil, nil, nil   -- leave it alone; another live server owns it
				end
				saved = saved or {}
				saved.lock = { jobId = JOB_ID, heartbeat = os.time() }
				return saved, nil, nil
			end
			data = store:UpdateAsync(key(player), claim)
		end)

		if ok and not blocked then
			claimed = true
			break
		end

		if not ok then
			lastErr = err
			if isApiDisabled(err) then
				if not studioNoApi then
					studioNoApi = true
					warn("[DataService] Studio API access is off — running with in-memory saves. " ..
						"Turn on Game Settings → Security → Enable Studio Access to API Services to test real saving.")
				end
				data = nil
				claimed = true
				break
			end
		end

		if player.Parent == nil then
			loading[player] = nil
			return nil
		end
		if attempt < LOAD_ATTEMPTS then task.wait(LOAD_RETRY_WAIT) end
	end

	if not claimed then
		loading[player] = nil
		if player.Parent then
			if lastErr then
				warn(("[DataService] load failed for %s: %s"):format(player.Name, tostring(lastErr)))
			else
				warn(("[DataService] profile for %s is still locked by another server"):format(player.Name))
			end
			-- Do NOT hand out a fresh profile on a failed read — that overwrites real progress
			-- on the next autosave. Kick instead and let them rejoin.
			player:Kick("Couldn't load your farm. Please rejoin — your progress is safe.")
		end
		return nil
	end

	local profile = migrate(reconcile(data or {}, DataService.default()))
	profiles[player] = profile
	loading[player] = nil
	return profile
end

-- Hooks other services use to fold their own in-memory state into the profile
-- immediately before it is written, and to restore it right after a load.
local serializers: { (Player, any) -> any } = {}

function DataService.onSerialize(fn: (Player, any) -> any)
	table.insert(serializers, fn)
end

-- Returns true only when the profile is known to be durably stored.
function DataService.save(player: Player, isFinal: boolean?): boolean
	local p = profiles[player]
	if not p then return false end

	for _, fn in ipairs(serializers) do
		local ok, err = pcall(fn, player, p)
		if not ok then warn(("[DataService] serializer failed: %s"):format(tostring(err))) end
	end

	if isFinal then
		p.lastLogout = os.time()
		p.rateAtLogout = DataService.poopRate(player)
		p.itemRateAtLogout = DataService.poopItemRate(player)
	end
	-- same cadence as the profile itself; spawned so a slow ordered-store write
	-- cannot hold up the save that actually matters
	task.spawn(DataService.publishScores, player, p)
	if studioNoApi then return true end

	local snapshot = deepCopy(p)
	-- `isFinal and nil or {...}` would always pick the table, because `x and nil`
	-- is nil and nil is falsy. The final save must clear the lock, not refresh it.
	if isFinal then
		snapshot.lock = nil
	else
		snapshot.lock = { jobId = JOB_ID, heartbeat = os.time() }
	end

	local lastErr
	for attempt = 1, 3 do
		local function commit(saved: any): (any, { number }?, any)
			-- Another server took the profile while we held it. Its data is newer
			-- than ours; writing now would roll that player back.
			if lockIsForeign(saved) then return nil, nil, nil end
			return snapshot, nil, nil
		end
		local ok, err = pcall(function()
			store:UpdateAsync(key(player), commit)
		end)
		if ok then return true end
		lastErr = err
		if isApiDisabled(err) then return true end
		task.wait(attempt * 2)
	end

	warn(("[DataService] save failed for %s: %s"):format(player.Name, tostring(lastErr)))
	return false
end

function DataService.init()
	Players.PlayerAdded:Connect(function(player)
		local profile = loadProfile(player)
		if not profile then return end
		-- leaderstats so the in-world boards and the Roblox player list work
		local stats = Instance.new("Folder")
		stats.Name = "leaderstats"
		local cash = Instance.new("NumberValue")
		cash.Name = "Cash"; cash.Value = profile.cash; cash.Parent = stats
		local rb = Instance.new("IntValue")
		rb.Name = "Rebirths"; rb.Value = profile.rebirths; rb.Parent = stats
		stats.Parent = player
	end)

	Players.PlayerRemoving:Connect(function(player)
		DataService.save(player, true)
		profiles[player] = nil
	end)

	-- autosave loop
	task.spawn(function()
		while true do
			task.wait(AUTOSAVE)
			for player in pairs(profiles) do
				task.spawn(DataService.save, player, false)
			end
		end
	end)

	-- keep leaderstats + playtime in step
	task.spawn(function()
		while true do
			task.wait(1)
			for player, p in pairs(profiles) do
				p.stats.playtime += 1
				p.stats.bestCash = math.max(p.stats.bestCash, p.cash)
				local ls = player:FindFirstChild("leaderstats")
				if ls then
					ls.Cash.Value = math.min(p.cash, 2 ^ 53)
					ls.Rebirths.Value = p.rebirths
				end
			end
		end
	end)

	game:BindToClose(function()
		for player in pairs(profiles) do
			DataService.save(player, true)
		end
		if RunService:IsStudio() then task.wait(1) else task.wait(3) end
	end)

	-- A full push serialises the entire profile, so this is worth a limit even
	-- though a legitimate client only asks once on join.
	local RemoteGuard = require(script.Parent.Parent.Security.RemoteGuard)
	RemoteGuard.handle(Net.NAMES.RequestState, { burst = 5, perSecond = 1 }, function(player)
		DataService.push(player)
	end)
end

return DataService
