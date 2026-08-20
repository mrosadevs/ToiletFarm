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

local store = DataStoreService:GetDataStore(STORE_NAME)

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
		upgrades      = upgrades,
		perks         = perks,
		discovered    = {},     -- ["T01_PorcelainStarter"] = true
		luckyInv      = {},     -- { {id="Basic", uid="..."} }
		codes         = {},
		settings      = { Music = 0.5, Sfx = 0.8, MuteToilets = false, AutoPoop = false, AutoCash = false },
		stats         = { playtime = 0, totalDeposited = 0, bestCash = 0 },
		tutorial      = 1,      -- current step index; 0 once finished
		lastLogout    = 0,
		rateAtLogout  = 0,
		version       = 1,
	}
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

-- ── load / save ───────────────────────────────────────────────────────────
local function loadProfile(player: Player)
	loading[player] = true
	local data
	local ok, err = pcall(function()
		data = store:GetAsync(key(player))
	end)
	if not ok then
		if isApiDisabled(err) then
			if not studioNoApi then
				studioNoApi = true
				warn("[DataService] Studio API access is off — running with in-memory saves. " ..
					"Turn on Game Settings → Security → Enable Studio Access to API Services to test real saving.")
			end
			data = nil
		else
			warn(("[DataService] load failed for %s: %s"):format(player.Name, tostring(err)))
			-- Do NOT hand out a fresh profile on a failed read — that overwrites real progress
			-- on the next autosave. Kick instead and let them rejoin.
			loading[player] = nil
			if player.Parent then
				player:Kick("Couldn't load your farm. Please rejoin — your progress is safe.")
			end
			return nil
		end
	end
	local profile = reconcile(data or {}, DataService.default())
	profiles[player] = profile
	loading[player] = nil
	return profile
end

function DataService.save(player: Player, isFinal: boolean?)
	local p = profiles[player]
	if not p then return end
	if isFinal then
		p.lastLogout = os.time()
		p.rateAtLogout = DataService.poopRate(player)
	end
	if studioNoApi then return end
	local snapshot = table.clone(p)
	local ok, err = pcall(function()
		store:SetAsync(key(player), snapshot)
	end)
	if not ok and not isApiDisabled(err) then
		warn(("[DataService] save failed for %s: %s"):format(player.Name, tostring(err)))
	end
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

	Net.event(Net.NAMES.RequestState).OnServerEvent:Connect(function(player)
		DataService.push(player)
	end)
end

return DataService
