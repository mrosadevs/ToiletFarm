--!strict
-- EconomyService — depositing poop, banking cash, upgrades, rebirth and offline earnings.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.ToiletConfig)
local Format = require(Shared.Format)
local Net = require(Shared.Net)
local DataService = require(script.Parent.DataService)
local PlotService = require(script.Parent.PlotService)
local PassService = require(script.Parent.PassService)
local FlushMeterService = require(script.Parent.FlushMeterService)
local ToiletService = require(script.Parent.ToiletService)

local DepositedEvent = Net.event(Net.NAMES.Deposited)
local CashEvent      = Net.event(Net.NAMES.CashCollected)
local ToastEvent     = Net.event(Net.NAMES.Toast)
local OfflineEvent   = Net.event(Net.NAMES.OfflineReport)

local EconomyService = {}

-- cash that has finished processing and is waiting on the Collect Cash pad
local pending: { [Player]: number } = {}
-- the selling queue: poop deposited but not yet sold, and the cash it will become
local queuePoops: { [Player]: number } = {}
local queueCash:  { [Player]: number } = {}
-- What the offline modal is currently offering, so Claim can't be replayed for more.
-- `offlineClaimed` keeps the amount after a plain claim so that a DoubleOffline
-- purchase arriving afterwards can still pay the second half.
local offlineOffer: { [Player]: number } = {}
local offlineClaimed: { [Player]: number } = {}

function EconomyService.pendingCash(player: Player): number
	return pending[player] or 0
end

function EconomyService.queued(player: Player): (number, number)
	return queuePoops[player] or 0, queueCash[player] or 0
end

-- friends in this server drive the sign's "(No Friend Boost)" line
--
-- IsFriendsWith is a web call. This used to be recomputed for every player on every
-- Heartbeat, which meant a yielding request per pair of players 60 times a second.
-- The answer can only change when somebody joins or leaves, so it is computed then
-- and read from the cache everywhere else.
local friendCache: { [Player]: number } = {}

local function recountFriends()
	local players = Players:GetPlayers()
	for _, player in ipairs(players) do
		task.spawn(function()
			local n = 0
			for _, other in ipairs(players) do
				if other ~= player then
					local ok, isFriend = pcall(function() return player:IsFriendsWith(other.UserId) end)
					if ok and isFriend then n += 1 end
				end
			end
			if player.Parent then friendCache[player] = n end
		end)
	end
end

function EconomyService.friendsInServer(player: Player): number
	return friendCache[player] or 0
end

function EconomyService.processRate(player: Player): number
	local p = DataService.get(player)
	if not p then return Config.PROCESSING.baseRate end
	local level = p.processing or 0
	local rate = Config.processRate(level, EconomyService.friendsInServer(player))
	-- Config alone starts at 1 poop/sec while a starting farm already earns
	-- thousands, so the queue could never drain. Scale the floor with the upgrade
	-- level as well, or the pad charges real money for a rate nobody would notice:
	-- level 0 exactly keeps up with production, and every level drains that much
	-- faster on top.
	local produced = DataService.poopRate(player)
	local minimum = produced * (1 + level)
	if minimum > rate then rate = minimum end
	return rate
end

local function toast(player: Player, text: string, kind: string?)
	ToastEvent:FireClient(player, text, kind or "info")
end

-- ── deposit ──────────────────────────────────────────────────────────────
function EconomyService.deposit(player: Player)
	local p = DataService.get(player)
	if not p then return end
	local value = p.poops
	local items = p.poopItems
	if value <= 0 then return end

	-- The Flush Meter is locked in at the moment of deposit, so sprinting to bank a
	-- good roll matters even though the cash arrives gradually.
	local meter = FlushMeterService.multiplier()
	local cash = value * meter * DataService.cashMultiplier(player)

	p.poops = 0
	p.poopItems = 0
	p.stats.totalDeposited += value

	-- into the selling queue, not straight to cash
	queuePoops[player] = (queuePoops[player] or 0) + value
	queueCash[player]  = (queueCash[player] or 0) + cash

	-- `count` drives the "Deposited X Poops!" banner, `value` drives the cash maths
	DepositedEvent:FireClient(player, { poops = value, count = items, cash = cash, multiplier = meter })
	DataService.push(player, { poops = 0, poopItems = 0 })
	return items, cash
end

-- ── collect banked cash ──────────────────────────────────────────────────
function EconomyService.collectCash(player: Player, worldPos: Vector3?)
	local p = DataService.get(player)
	if not p then return end
	local amount = pending[player] or 0
	if amount <= 0 then return end
	pending[player] = 0
	p.cash += amount
	CashEvent:FireClient(player, { amount = amount, pos = worldPos })
	DataService.push(player, { cash = p.cash })
	return amount
end

-- ── upgrades ───────────────────────────────────────────────────────────
-- ── the selling queue ───────────────────────────────────────────────────────
local function tickQueue(player: Player, dt: number)
	local remaining = queuePoops[player] or 0
	if remaining <= 0 then return end
	local sold = math.min(remaining, EconomyService.processRate(player) * dt)
	if sold <= 0 then return end
	-- move the same proportion of cash as of poop, so the locked-in meter is preserved
	local fraction = sold / remaining
	local cash = (queueCash[player] or 0) * fraction
	queuePoops[player] = remaining - sold
	queueCash[player] = (queueCash[player] or 0) - cash
	if queuePoops[player] < 0.001 then
		-- flush the rounding dust so the queue can actually reach zero
		cash += queueCash[player] or 0
		queuePoops[player] = 0
		queueCash[player] = 0
	end
	pending[player] = (pending[player] or 0) + cash
end

-- "Finish Now" — clears the whole queue instantly
function EconomyService.finishProcessing(player: Player)
	local q = queuePoops[player] or 0
	if q <= 0 then
		toast(player, "Nothing is processing!", "error")
		return false
	end
	pending[player] = (pending[player] or 0) + (queueCash[player] or 0)
	queuePoops[player] = 0
	queueCash[player] = 0
	toast(player, "Processing finished!", "reward")
	return true
end

function EconomyService.buyProcessing(player: Player)
	local p = DataService.get(player)
	if not p then return end
	local level = p.processing or 0
	local cost = Config.processCost(level)
	if not cost then toast(player, "Processing is maxed!", "error") return end
	if p.cash < cost then toast(player, "Not enough cash!", "error") return end
	p.cash -= cost
	p.processing = level + 1
	DataService.push(player, { cash = p.cash, processing = p.processing })
	toast(player, ("Processing → %s/sec"):format(Format.short(Config.processRate(p.processing))), "reward")
	return true
end

function EconomyService.buyUpgrade(player: Player, key: string)
	local p = DataService.get(player)
	if not p or not Config.UPGRADES[key] then return end
	local level = p.upgrades[key] or 0
	local cost = Config.upgradeCost(key, level)
	if not cost then toast(player, "Already max level!", "error") return end
	if p.cash < cost then toast(player, "Not enough cash!", "error") return end
	p.cash -= cost
	p.upgrades[key] = level + 1
	if key == "PlotSlots" then PlotService.refreshStalls(player) end
	DataService.push(player)
	toast(player, ("%s → level %d"):format(Config.UPGRADES[key].label, level + 1), "reward")
	return true
end

-- ── Flush Token perks ─────────────────────────────────────────────────────
function EconomyService.buyPerk(player: Player, id: string)
	local p = DataService.get(player)
	if not p then return end
	for _, perk in ipairs(Config.TOKEN_PERKS) do
		if perk.id == id then
			local owned = p.perks[id] or 0
			if owned >= perk.max then toast(player, "Already maxed!", "error") return end
			if p.tokens < perk.cost then toast(player, "Not enough Flush Tokens!", "error") return end
			p.tokens -= perk.cost
			p.perks[id] = owned + 1
			if id == "ExtraPlot" then PlotService.refreshStalls(player) end
			DataService.push(player)
			toast(player, perk.label .. " unlocked!", "reward")
			return true
		end
	end
end

-- ── rebirth ──────────────────────────────────────────────────────────────
function EconomyService.canRebirth(player: Player): (boolean, number?)
	local p = DataService.get(player)
	if not p then return false end
	local cost = Config.rebirthCost(p.rebirths)
	if not cost then return false end
	return p.cash >= cost, cost
end

function EconomyService.rebirth(player: Player)
	local p = DataService.get(player)
	if not p then return end
	local ok, cost = EconomyService.canRebirth(player)
	if not ok then
		if not cost then toast(player, "You're at max rebirth!", "error")
		else toast(player, "Not enough cash to rebirth!", "error") end
		return
	end

	local entry = Config.REBIRTHS[p.rebirths + 1]
	p.rebirths += 1
	p.tokens += entry.tokens

	-- wipe: cash, poops, toilets, upgrades, purchased slots, pending cash
	p.cash = 10
	p.poops = 0
	p.poopItems = 0
	p.toilets = {}
	p.processing = 0
	p.buyTier = 1   -- the ceiling grew, but you re-earn the tier itself each run
	for key in pairs(Config.UPGRADES) do p.upgrades[key] = 0 end
	pending[player] = 0
	queuePoops[player] = 0
	queueCash[player] = 0

	local plot = PlotService.plotFor(player)
	if plot then
		for slot = 1, 48 do PlotService.clearToilet(plot, slot) end
		local bin = plot:FindFirstChild("WorldPoops")
		if bin then bin:ClearAllChildren() end
	end

	-- Head Start perk: begin the new run with one cap-tier toilet
	if (p.perks.HeadStart or 0) > 0 then
		local tier = Config.maxBuyableTier(p.rebirths)
		table.insert(p.toilets, { tier = tier, mut = "None", slot = 1 })
	end

	PlotService.rebuild(player)
	ToiletService.resetTimers(player)
	DataService.push(player)
	toast(player, ("REBIRTH %d! Now x%s income"):format(p.rebirths, entry.mult), "reward")
	return true
end

-- ── Upgrade Buy Tier ─────────────────────────────────────────────────────
-- Raising the tier the Buy pads sell. Costs cash AND requires a total-toilet
-- count, and can never exceed the ceiling your rebirth level allows.
function EconomyService.upgradeBuyTier(player: Player)
	local p = DataService.get(player)
	if not p then return end
	local tier = p.buyTier or 1
	local ceiling = Config.maxBuyTier(p.rebirths)
	if tier >= ceiling then
		toast(player, ("Rebirth %d to unlock the next Buy Tier!"):format(p.rebirths + 1), "error")
		return
	end
	local need = Config.buyTierRequirement(tier)
	local owned = ToiletService.totalToilets(player)
	if owned < need then
		toast(player, ("Need %s toilets to upgrade (you have %s)")
			:format(Format.short(need), Format.short(owned)), "error")
		return
	end
	local cost = Config.buyTierCost(tier)
	if p.cash < cost then
		toast(player, "Not enough cash to upgrade your Buy Tier!", "error")
		return
	end
	p.cash -= cost
	p.buyTier = tier + 1
	DataService.push(player, { cash = p.cash, buyTier = p.buyTier })
	toast(player, ("Buy Tier %d! Now buying %s"):format(p.buyTier, Config.displayName(p.buyTier)), "reward")
	return true
end

-- ── offline earnings ─────────────────────────────────────────────────────
function EconomyService.reportOffline(player: Player)
	local p = DataService.get(player)
	if not p then return end
	if p.lastLogout == 0 then return end   -- first-ever join awards nothing

	local away = os.time() - p.lastLogout
	if away < 0 then
		-- clock skew: never award on a negative interval
		warn(("[Economy] negative offline interval for %s (%d)"):format(player.Name, away))
		return
	end
	if away < Config.OFFLINE_MIN_SHOW then return end

	local hasPass = PassService.has(player, "ExtendedSeptic")
	-- rateAtLogout is persisted, never recomputed: recomputing pays out at today's
	-- tier table for time earned under yesterday's
	local poops = Config.offlinePoop(p.rateAtLogout or 0, away, hasPass)
	if poops <= 0 then return end

	offlineOffer[player] = poops
	offlineClaimed[player] = nil
	OfflineEvent:FireClient(player, { poops = poops, seconds = math.min(away, hasPass and Config.OFFLINE_CAP_PASS or Config.OFFLINE_CAP) })
end

-- `doubled` is only ever passed by the DoubleOffline receipt handler, never by the
-- client. Claiming normally used to clear the offer outright, so a player who hit
-- Claim and then bought the x2 left the receipt with nothing to grant — it returned
-- nil, ProcessReceipt answered NotProcessedYet, and Roblox retried that forever.
-- The claimed amount is now remembered so the purchase can pay the missing half.
function EconomyService.claimOffline(player: Player, doubled: boolean?)
	local p = DataService.get(player)
	if not p then return end

	local amount
	if doubled then
		if offlineOffer[player] then
			-- bought before claiming: pay both halves at once
			amount = offlineOffer[player] * 2
		elseif offlineClaimed[player] then
			-- already claimed at 1x: pay only the bonus half
			amount = offlineClaimed[player]
		end
		-- either way the doubling is spent, so a second purchase cannot re-double
		offlineClaimed[player] = nil
	else
		amount = offlineOffer[player]
		if amount then offlineClaimed[player] = amount end
	end

	offlineOffer[player] = nil
	-- Nothing outstanding. Returning falsy keeps ProcessReceipt on NotProcessedYet,
	-- which leaves the purchase uncharged rather than taking Robux for nothing.
	if not amount or amount <= 0 then return end

	-- The offline pile arrives as one lump of value rather than as individual poops,
	-- so it bypasses the item cap by design — the player still has to walk it to the
	-- Septic Tank, which is the point of paying out in poop instead of cash.
	p.poops += amount
	DataService.push(player, { poops = p.poops })
	return true
end

-- ── free money chest ────────────────────────────────────────────────────
local CHEST_COOLDOWN = 600

-- The cooldown is stored against wall-clock time in the profile. It used to be
-- os.clock(), which counts this server's uptime, so hopping to a fresh server
-- reset the chest instantly and it could be farmed as fast as a player could
-- rejoin.
function EconomyService.freeMoney(player: Player)
	local p = DataService.get(player)
	if not p then return end
	local now = os.time()
	local last = tonumber(p.lastChestAt) or 0
	-- a clock that has moved backwards must not hand out a free claim
	if last > now then last = now end
	if last > 0 and now - last < CHEST_COOLDOWN then
		local left = math.ceil(CHEST_COOLDOWN - (now - last))
		toast(player, ("Chest refills in %dm %ds"):format(left // 60, left % 60), "error")
		return
	end
	p.lastChestAt = now
	-- scaled to the player's progress so it stays relevant after rebirths
	local reward = math.max(250, Config.buyCost(Config.maxBuyableTier(p.rebirths)) * 2)
	p.cash += reward
	CashEvent:FireClient(player, { amount = reward })
	DataService.push(player, { cash = p.cash })
	toast(player, "Free money claimed!", "reward")
	return reward
end

-- ── persistence ──────────────────────────────────────────────────────────
-- Banked cash and the selling queue used to live only in these tables, so logging
-- out with a full basket deposited and still processing silently destroyed all of
-- it. They are part of the player's balance and belong in the profile.
local function restore(player: Player)
	local p = DataService.get(player)
	if not p then return end
	pending[player]    = tonumber(p.pendingCash) or 0
	queuePoops[player] = tonumber(p.queuePoops) or 0
	queueCash[player]  = tonumber(p.queueCash) or 0
end

local function capture(player: Player, p)
	p.pendingCash = pending[player] or 0
	p.queuePoops  = queuePoops[player] or 0
	p.queueCash   = queueCash[player] or 0
end

function EconomyService.init()
	DataService.onSerialize(capture)

	Players.PlayerAdded:Connect(function(player)
		-- DataService loads the profile on its own PlayerAdded; wait for it rather
		-- than racing it, or the restore reads a profile that is not there yet.
		local deadline = os.clock() + 30
		while not DataService.isLoaded(player) and os.clock() < deadline and player.Parent do
			task.wait(0.1)
		end
		if DataService.isLoaded(player) then restore(player) end
	end)
	for _, player in ipairs(Players:GetPlayers()) do
		if DataService.isLoaded(player) then restore(player) end
	end

	Players.PlayerRemoving:Connect(function(player)
		-- DataService.save(player, true) runs the serializer before writing, so the
		-- numbers are already captured by the time these are cleared.
		pending[player] = nil
		queuePoops[player] = nil
		queueCash[player] = nil
		offlineOffer[player] = nil
		offlineClaimed[player] = nil
	end)

	recountFriends()
	Players.PlayerAdded:Connect(recountFriends)
	Players.PlayerRemoving:Connect(function(player)
		friendCache[player] = nil
		task.defer(recountFriends)
	end)

	-- Drain the selling queue.
	--
	-- This is an economic process, not a visual one, so it does not need to run at
	-- frame rate: each tick sells rate * elapsed, and accumulating the elapsed time
	-- over a fifth of a second sells exactly as much as twelve frame-sized ticks
	-- would have. Doing it per frame meant rebuilding every player's full toilet
	-- rate table 60 times a second for no additional accuracy.
	local TICK = 0.2
	local accumulated = 0
	RunService.Heartbeat:Connect(function(dt)
		accumulated += dt
		if accumulated < TICK then return end
		local elapsed = accumulated
		accumulated = 0
		for _, player in ipairs(Players:GetPlayers()) do
			tickQueue(player, elapsed)
		end
	end)

	-- Auto Cash gamepass drip
	task.spawn(function()
		while true do
			task.wait(2)
			for _, player in ipairs(Players:GetPlayers()) do
				if (pending[player] or 0) > 0 and PassService.has(player, "AutoCash") then
					EconomyService.collectCash(player)
				end
			end
		end
	end)
end

return EconomyService
