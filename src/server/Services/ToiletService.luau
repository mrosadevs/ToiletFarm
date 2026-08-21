--!strict
-- ToiletService — buying, merging, and the drop loop that turns toilets into poop.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.ToiletConfig)
local Net = require(Shared.Net)
local DataService = require(script.Parent.DataService)
local PlotService = require(script.Parent.PlotService)
local PoopService = require(script.Parent.PoopService)
local PassService = require(script.Parent.PassService)
local IndexService = require(script.Parent.IndexService)

local ToastEvent = Net.event(Net.NAMES.Toast)
local MergeResult = Net.event(Net.NAMES.MergeResult)

local ToiletService = {}

-- runtime drop timers, never saved: [player] = { [slot] = secondsUntilNextDrop }
local timers: { [Player]: { [number]: number } } = {}

local function toast(player: Player, text: string, kind: string?)
	ToastEvent:FireClient(player, text, kind or "info")
end

-- ── buying ────────────────────────────────────────────────────────────────
-- The buy buttons always sell the best tier the player can currently afford *and* is
-- allowed to buy — same as the reference game, so the button price ticks up as you grow.
-- "Total Toilets": merge-equivalents, so a Tier 4 counts as MERGE_COUNT^3.
-- This is what the Upgrade Buy Tier requirement is measured against.
function ToiletService.totalToilets(player: Player): number
	local p = DataService.get(player)
	if not p then return 0 end
	local n = 0
	for _, t in ipairs(p.toilets) do
		n += Config.MERGE_COUNT ^ ((t.tier or 1) - 1)
	end
	return n
end

-- The buy pads always sell your current Buy Tier, exactly like the reference
-- game. You raise it at the Upgrade Buy Tier pad, not by getting richer.
function ToiletService.currentBuyTier(player: Player): number
	local p = DataService.get(player)
	if not p then return 1 end
	return math.clamp(p.buyTier or 1, 1, Config.maxBuyTier(p.rebirths))
end

-- The unit price climbs with the size of the farm, so it is quoted once per
-- purchase batch and every toilet in that batch costs the same. That is what makes
-- "Buy 25" exactly 25x the "Buy 1" figure on the pads, as in the reference game.
function ToiletService.bestAffordableTier(player: Player): (number?, number?)
	local tier = ToiletService.currentBuyTier(player)
	local p = DataService.get(player)
	-- the balance goes in too, so the price cannot fall behind what the player holds
	return tier, Config.buyCostFor(tier, ToiletService.totalToilets(player), p and p.cash)
end

-- what the button should display: tier and unit price of the next purchase
function ToiletService.buyPreview(player: Player, amount: number): (number, number, number)
	local p = DataService.get(player)
	if not p then return 1, Config.buyCost(1), 0 end
	-- take the quoted price, not Config.buyCost: the pads must advertise the same
	-- farm-scaled figure the purchase will actually charge
	local tier, unit = ToiletService.bestAffordableTier(player)
	tier = tier or 1
	unit = unit or Config.buyCost(tier)
	local free = DataService.slots(player)
	local used = #p.toilets
	local affordable = math.floor(p.cash / unit)
	local canPlace = math.max(0, free - used)
	return tier, unit, math.min(amount, affordable, canPlace)
end

-- Merging keeps the lowest of the three slots and frees the other two, so a farm
-- that has merged a few times ends up occupying 1, 4, 7, 10 ... and the stall grid
-- shows holes. Slide everything down so the occupied slots are always 1..N.
-- Only toilets that actually move are rebuilt.
local function compactSlots(player: Player): boolean
	local p = DataService.get(player)
	local plot = PlotService.plotFor(player)
	if not p or not plot then return false end

	table.sort(p.toilets, function(a, b) return a.slot < b.slot end)

	local t = timers[player] or {}
	local newTimers: { [number]: number } = {}
	local moved = false

	-- ascending, and after sorting slot >= index always holds, so the destination
	-- slot has already been vacated by the time we write to it
	for i, entry in ipairs(p.toilets) do
		local from = entry.slot
		local carried = t[from] or Config.dropInterval(entry.tier)
		if from ~= i then
			moved = true
			PlotService.clearToilet(plot, from)
			entry.slot = i
			PlotService.buildToilet(plot, i, entry.tier, entry.mut)
		end
		newTimers[i] = carried
	end

	timers[player] = newTimers
	if moved then PlotService.refreshStalls(player) end
	return moved
end

function ToiletService.buy(player: Player, amount: number)
	local p = DataService.get(player)
	local plot = PlotService.plotFor(player)
	if not p or not plot then return end
	amount = math.clamp(math.floor(tonumber(amount) or 1), 1, 100)

	-- quote the price once for the whole batch
	local quotedTier, quotedCost = ToiletService.bestAffordableTier(player)
	if not quotedTier or not quotedCost then return end

	local bought, spent, lastTier = 0, 0, nil
	for _ = 1, amount do
		local tier, cost = quotedTier, quotedCost
		if p.cash < cost then break end
		local slot = PlotService.freeSlot(player)
		if not slot then
			if bought == 0 then toast(player, "No free plot slots — merge or buy more!", "error") end
			break
		end
		-- place it first: if the stall cannot be built we must not charge for it,
		-- or the player pays for a toilet that never appears
		local entry = { tier = tier, mut = "None", slot = slot }
		table.insert(p.toilets, entry)
		if not PlotService.buildToilet(plot, slot, tier, "None") then
			table.remove(p.toilets, #p.toilets)
			warn(("[ToiletService] could not build tier %d in slot %d, purchase refunded")
				:format(tier, slot))
			break
		end
		p.cash -= cost
		spent += cost
		timers[player] = timers[player] or {}
		timers[player][slot] = Config.dropInterval(tier)
		IndexService.discover(player, Config.assetId(tier))
		bought += 1
		lastTier = tier
	end

	if bought == 0 then
		if PlotService.freeSlot(player) then toast(player, "Not enough cash!", "error") end
		return
	end
	compactSlots(player)
	DataService.push(player)
	return bought, lastTier, spent
end

-- ── merging ──────────────────────────────────────────────────────────────
-- Place a toilet the player did not pay for (Lucky Block rewards). Mirrors the
-- placement half of buy(): reserve the slot, build it, and roll the entry back if
-- the stall cannot be built, so a failed build never leaves a phantom toilet in
-- the save. Returns the slot, or nil plus a reason.
function ToiletService.grant(player: Player, tier: number): (number?, string?)
	local p = DataService.get(player)
	local plot = PlotService.plotFor(player)
	if not p or not plot then return nil, "noplot" end
	tier = math.clamp(math.floor(tonumber(tier) or 1), 1, Config.MAX_TIER)

	local slot = PlotService.freeSlot(player)
	if not slot then return nil, "nospace" end

	local entry = { tier = tier, mut = "None", slot = slot }
	table.insert(p.toilets, entry)
	if not PlotService.buildToilet(plot, slot, tier, "None") then
		table.remove(p.toilets, #p.toilets)
		warn(("[ToiletService] could not build granted tier %d in slot %d"):format(tier, slot))
		return nil, "buildfailed"
	end

	timers[player] = timers[player] or {}
	timers[player][slot] = Config.dropInterval(tier)
	IndexService.discover(player, Config.assetId(tier))
	compactSlots(player)
	DataService.push(player)
	return entry.slot
end

local MUT_RANK = { None = 0 }
for i, name in ipairs(Config.MUTATION_ORDER) do MUT_RANK[name] = i end

-- one pass: merge every eligible triple, lowest tier first so cascades resolve upward
local function mergeOnce(player: Player): (number, number?)
	local p = DataService.get(player)
	local plot = PlotService.plotFor(player)
	if not p or not plot then return 0, nil end

	local byTier: { [number]: { any } } = {}
	for _, t in ipairs(p.toilets) do
		if t.tier < Config.MAX_TIER then
			byTier[t.tier] = byTier[t.tier] or {}
			table.insert(byTier[t.tier], t)
		end
	end

	local tiers = {}
	for tier in pairs(byTier) do table.insert(tiers, tier) end
	table.sort(tiers)

	local merges, highest = 0, nil
	for _, tier in ipairs(tiers) do
		local group = byTier[tier]
		while #group >= Config.MERGE_COUNT do
			local inputs = {}
			for _ = 1, Config.MERGE_COUNT do table.insert(inputs, table.remove(group)) end

			-- the result inherits the BEST mutation of the three inputs.
			-- Losing a Rainbow to a merge feels awful and makes players stop merging,
			-- which breaks the core loop — so never drop it.
			local bestMut = "None"
			for _, t in ipairs(inputs) do
				if (MUT_RANK[t.mut] or 0) > (MUT_RANK[bestMut] or 0) then bestMut = t.mut end
			end

			-- keep the lowest slot for the result, free the other two
			table.sort(inputs, function(a, b) return a.slot < b.slot end)
			local keep = inputs[1]
			for i = 2, #inputs do
				local doomed = inputs[i]
				PlotService.clearToilet(plot, doomed.slot)
				for idx, t in ipairs(p.toilets) do
					if t == doomed then table.remove(p.toilets, idx) break end
				end
				if timers[player] then timers[player][doomed.slot] = nil end
			end

			keep.tier = tier + 1
			keep.mut = bestMut
			PlotService.buildToilet(plot, keep.slot, keep.tier, keep.mut)
			timers[player] = timers[player] or {}
			timers[player][keep.slot] = Config.dropInterval(keep.tier)
			IndexService.discover(player, Config.assetId(keep.tier))

			byTier[keep.tier] = byTier[keep.tier] or {}
			table.insert(byTier[keep.tier], keep)
			if keep.tier < Config.MAX_TIER and not table.find(tiers, keep.tier) then
				table.insert(tiers, keep.tier)
				table.sort(tiers)
			end

			merges += 1
			highest = math.max(highest or 0, keep.tier)
		end
	end
	return merges, highest
end

-- How many merges "Merge All" would perform right now, cascades included. The
-- Merge pad greys itself out on a zero, so this has to mirror mergeOnce's
-- eligibility exactly: anything below MAX_TIER counts, mutated or not.
function ToiletService.pendingMerges(player: Player): number
	local p = DataService.get(player)
	if not p then return 0 end

	local count: { [number]: number } = {}
	for _, t in ipairs(p.toilets) do
		local tier = t.tier or 1
		if tier < Config.MAX_TIER then count[tier] = (count[tier] or 0) + 1 end
	end

	local total = 0
	for tier = 1, Config.MAX_TIER - 1 do
		local made = math.floor((count[tier] or 0) / Config.MERGE_COUNT)
		if made > 0 then
			total += made
			-- the results are themselves mergeable, which is why one step on the pad
			-- can cascade several tiers up
			if tier + 1 < Config.MAX_TIER then
				count[tier + 1] = (count[tier + 1] or 0) + made
			end
		end
	end
	return total
end

-- "Merge All" — keeps going until nothing else can merge
function ToiletService.mergeAll(player: Player)
	local total, highest = 0, nil
	for _ = 1, 40 do
		local n, h = mergeOnce(player)
		if n == 0 then break end
		total += n
		highest = math.max(highest or 0, h or 0)
	end
	if total > 0 then
		compactSlots(player)
		DataService.push(player)
		MergeResult:FireClient(player, highest, total)
		-- server-side so anyone standing on the farm sees the merge, not just the owner
		require(script.Parent.VfxService).playAt(player, "merge", Vector3.new(0, -1.5, 0))
	else
		toast(player, "Nothing to merge — you need 3 of a kind.", "error")
	end
	return total
end

-- ── mutations ────────────────────────────────────────────────────────────
function ToiletService.applyMutation(player: Player, mut: string): boolean
	local p = DataService.get(player)
	local plot = PlotService.plotFor(player)
	if not p or not plot or mut == "None" then return false end
	if #p.toilets == 0 then
		toast(player, "Buy a toilet first!", "error")
		return false
	end
	-- apply to the highest-tier toilet that would gain the most from it
	local best
	for _, t in ipairs(p.toilets) do
		if (MUT_RANK[t.mut] or 0) < (MUT_RANK[mut] or 0) then
			if not best or t.tier > best.tier then best = t end
		end
	end
	best = best or p.toilets[1]
	best.mut = mut
	PlotService.buildToilet(plot, best.slot, best.tier, mut)
	IndexService.discover(player, "MUT_" .. mut)
	DataService.push(player)
	return true
end

-- ── the drop loop ────────────────────────────────────────────────────────
function ToiletService.resetTimers(player: Player)
	local p = DataService.get(player)
	if not p then return end
	local t = {}
	for _, entry in ipairs(p.toilets) do
		t[entry.slot] = Config.dropInterval(entry.tier) * math.random()
	end
	timers[player] = t
end

function ToiletService.init()
	Players.PlayerRemoving:Connect(function(player) timers[player] = nil end)

	RunService.Heartbeat:Connect(function(dt)
		for _, player in ipairs(Players:GetPlayers()) do
			local p = DataService.get(player)
			local plot = PlotService.plotFor(player)
			if not p or not plot then continue end
			local t = timers[player]
			if not t then continue end

			local speed = 1 - 0.03 * (p.upgrades.FlushSpeed or 0)
			local valueUp = 1 + 0.10 * (p.upgrades.PoopValue or 0)
			local mult = DataService.incomeMultiplier(player)

			for _, entry in ipairs(p.toilets) do
				local left = t[entry.slot]
				if left == nil then
					t[entry.slot] = Config.dropInterval(entry.tier)
					continue
				end
				left -= dt
				if left <= 0 then
					t[entry.slot] = Config.dropInterval(entry.tier) * speed
					-- There is no carry cap any more, so toilets always litter. The
					-- world-poop population is still bounded per plot in PoopService.drop.
					local model = PlotService.toiletModel(plot, entry.slot)
					if model then
						local value = Config.poopValue(entry.tier) * valueUp
							* (Config.MUTATIONS[entry.mut] or 1) * mult
						local cf = model:GetPivot()
						PoopService.drop(plot, cf.Position, entry.tier, entry.mut, value)
					end
				else
					t[entry.slot] = left
				end
			end

			-- Auto Merge gamepass
			if PassService.has(player, "AutoMerge") then
				local hasTriple = false
				local count: { [number]: number } = {}
				for _, e in ipairs(p.toilets) do
					if e.mut == "None" and e.tier < Config.MAX_TIER then
						count[e.tier] = (count[e.tier] or 0) + 1
						if count[e.tier] >= Config.MERGE_COUNT then hasTriple = true break end
					end
				end
				-- never auto-merge a mutated toilet without asking
				if hasTriple then ToiletService.mergeAll(player) end
			end
		end
	end)
end

return ToiletService
