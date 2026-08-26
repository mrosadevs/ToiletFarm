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
local Analytics = require(script.Parent.AnalyticsService)

local DepositedEvent = Net.event(Net.NAMES.Deposited)
local CashEvent = Net.event(Net.NAMES.CashCollected)
local ToastEvent = Net.event(Net.NAMES.Toast)
local OfflineEvent = Net.event(Net.NAMES.OfflineReport)

local EconomyService = {}

-- cash that has finished processing and is waiting on the Collect Cash pad
local pending: { [Player]: number } = {}
-- the selling queue: poop deposited but not yet sold, and the cash it will become
-- The queue is carried in three parallel figures for the same poop: its VALUE
-- (what the maths runs on), its COUNT (what the player is shown), and the cash it
-- will become. They drain together by the same fraction so they cannot drift.
--
-- The sign used to print queuePoops -- a value -- under the word "Poops", so
-- depositing 90 poops read as 9K. That is the same value-vs-count mixup the basket
-- and the offline modal had.
local queuePoops: { [Player]: number } = {}
local queueItems: { [Player]: number } = {}
local queueCash: { [Player]: number } = {}
-- What the offline modal is currently offering, so Claim can't be replayed for more.
-- `offlineClaimed` keeps the amount after a plain claim so that a DoubleOffline
-- purchase arriving afterwards can still pay the second half.
type OfflineOffer = { value: number, items: number }
local offlineOffer: { [Player]: OfflineOffer } = {}
local offlineClaimed: { [Player]: OfflineOffer } = {}

function EconomyService.pendingCash(player: Player): number
	return pending[player] or 0
end

function EconomyService.queued(player: Player): (number, number)
	return queuePoops[player] or 0, queueCash[player] or 0
end

-- How many poops are still in the queue, as the basket counts them.
function EconomyService.queuedItems(player: Player): number
	return queueItems[player] or 0
end

-- The drain rate in poops per second. processRate works in value, so it is
-- converted by the queue's own value-to-count ratio; with the queue empty there is
-- no ratio to read, so the farm's current production stands in.
function EconomyService.processItemRate(player: Player): number
	local rate = EconomyService.processRate(player)
	local value = queuePoops[player] or 0
	if value > 0 then return rate * ((queueItems[player] or 0) / value) end
	local produced = DataService.poopRate(player)
	if produced > 0 then return rate * (DataService.poopItemRate(player) / produced) end
	return 0
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
					local ok, isFriend = pcall(function()
						return player:IsFriendsWith(other.UserId)
					end)
					if ok and isFriend then
						n += 1
					end
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
	queueItems[player] = (queueItems[player] or 0) + items
	queueCash[player] = (queueCash[player] or 0) + cash

	-- `count` drives the "Deposited X Poops!" banner, `value` drives the cash maths
	DepositedEvent:FireClient(player, { poops = value, count = items, cash = cash, multiplier = meter })
	DataService.push(player, { poops = 0, poopItems = 0 })

	-- banking a run is the payoff of the whole loop, so it gets the confetti
	local hrp = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
	if hrp and hrp:IsA("BasePart") then
		require(script.Parent.VfxService).play("confetti", hrp.Position + Vector3.new(0, 1, 0), 30)
	end
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
	-- Pooled, not reported outright: Auto Collect Cash lands here every two seconds
	-- and would otherwise post an economy event on that same cadence all session.
	Analytics.cashEarnedPooled(player, amount, "PoopSales")
	-- only for a real walk-on collection; Auto Collect fires this every tick with no
	-- position and would otherwise spray particles continuously
	if worldPos then require(script.Parent.VfxService).play("cash", worldPos + Vector3.new(0, 2, 0)) end
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
	queueItems[player] = (queueItems[player] or 0) * (1 - fraction)
	queueCash[player] = (queueCash[player] or 0) - cash
	if queuePoops[player] < 0.001 then
		-- flush the rounding dust so the queue can actually reach zero
		cash += queueCash[player] or 0
		queuePoops[player] = 0
		queueItems[player] = 0
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
	queueItems[player] = 0
	queueCash[player] = 0
	toast(player, "Processing finished!", "reward")
	return true
end

function EconomyService.buyProcessing(player: Player)
	local p = DataService.get(player)
	if not p then return end
	local level = p.processing or 0
	local cost = Config.processCost(level)
	if not cost then
		toast(player, "Processing is maxed!", "error")
		return
	end
	if p.cash < cost then
		toast(player, "Not enough cash!", "error")
		return
	end
	p.cash -= cost
	p.processing = level + 1
	DataService.push(player, { cash = p.cash, processing = p.processing })
	Analytics.cashSpent(player, cost, p.cash, Enum.AnalyticsEconomyTransactionType.Shop, "Processing")
	toast(player, ("Processing → %s/sec"):format(Format.short(Config.processRate(p.processing))), "reward")
	return true
end

function EconomyService.buyUpgrade(player: Player, key: string)
	local p = DataService.get(player)
	if not p or not Config.UPGRADES[key] then return end
	local level = p.upgrades[key] or 0
	local cost = Config.upgradeCost(key, level)
	if not cost then
		toast(player, "Already max level!", "error")
		return
	end
	if p.cash < cost then
		toast(player, "Not enough cash!", "error")
		return
	end
	p.cash -= cost
	p.upgrades[key] = level + 1
	if key == "PlotSlots" then PlotService.refreshStalls(player) end
	DataService.push(player)
	-- one sku per upgrade, so the economy page shows which of them people buy
	Analytics.cashSpent(player, cost, p.cash, Enum.AnalyticsEconomyTransactionType.Shop, "Upgrade_" .. key)
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
			if owned >= perk.max then
				toast(player, "Already maxed!", "error")
				return
			end
			if p.tokens < perk.cost then
				toast(player, "Not enough Flush Tokens!", "error")
				return
			end
			p.tokens -= perk.cost
			p.perks[id] = owned + 1
			if id == "ExtraPlot" then PlotService.refreshStalls(player) end
			DataService.push(player)
			Analytics.tokensSpent(player, perk.cost, p.tokens, "Perk_" .. id)
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
		if not cost then
			toast(player, "You're at max rebirth!", "error")
		else
			toast(player, "Not enough cash to rebirth!", "error")
		end
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
	p.buyTier = 1 -- the ceiling grew, but you re-earn the tier itself each run
	for key in pairs(Config.UPGRADES) do
		p.upgrades[key] = 0
	end
	pending[player] = 0
	queuePoops[player] = 0
	queueItems[player] = 0
	queueCash[player] = 0

	local plot = PlotService.plotFor(player)
	if plot then
		-- every stall on the plot, not a pasted 48: the ceiling moves with
		-- Config.MAX_PLOT_SLOTS and a leftover toilet would be unreachable
		for slot = 1, Config.MAX_PLOT_SLOTS do
			PlotService.clearToilet(plot, slot)
		end
		local bin = plot:FindFirstChild("WorldPoops")
		if bin then bin:ClearAllChildren() end
	end

	-- Head Start perk: begin the new run with one cap-tier toilet
	if (p.perks.HeadStart or 0) > 0 then
		local tier = Config.maxBuyableTier(p.rebirths)
		table.insert(p.toilets, { tier = tier, slot = 1 })
	end

	PlotService.rebuild(player)
	ToiletService.resetTimers(player)
	DataService.push(player)
	toast(player, ("REBIRTH %d! Now x%s income"):format(p.rebirths, entry.mult), "reward")
	-- the one genuinely big moment in the loop; make it visible across the server
	require(script.Parent.VfxService).playAt(player, "confetti", Vector3.new(0, 0, 0), 40)

	-- What the rebirth cost, what it paid, and the step that closes the RebirthRun
	-- funnel and completes the progression level. Reported here rather than at the
	-- pad, so a rebirth that failed a check above is never counted as one that
	-- happened.
	if cost then
		Analytics.cashSpent(player, cost, p.cash, Enum.AnalyticsEconomyTransactionType.Gameplay, "Rebirth")
	end
	Analytics.tokensEarned(player, entry.tokens, p.tokens, "Rebirth")
	Analytics.rebirthed(player, p.rebirths)
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
		toast(
			player,
			("Need %s toilets to upgrade (you have %s)"):format(Format.short(need), Format.short(owned)),
			"error"
		)
		return
	end
	local cost = Config.buyTierCost(tier)
	if p.cash < cost then
		toast(player, "Not enough cash to upgrade your Buy Tier!", "error")
		return
	end
	p.cash -= cost
	p.buyTier = tier + 1
	toast(player, ("Buy Tier %d! Now buying %s"):format(p.buyTier, Config.displayName(p.buyTier)), "reward")

	-- Buy off whatever the new tier strands.
	--
	-- Once you buy above a tier you can never obtain that tier again, so anything
	-- left over that cannot reach three of a kind can never be merged and would sit
	-- on the farm as dead weight -- holding a stall -- until a rebirth.
	--
	-- Merge FIRST, so only the genuine remainder is bought back: after mergeAll no
	-- tier can have three of a kind left, so what remains below the new tier is one
	-- or two of each and is truly stuck. A farm full of mergeable Tier 1s is left
	-- alone, which is the difference between tidying up and confiscating a farm.
	ToiletService.mergeAll(player)

	local plot = PlotService.plotFor(player)
	local rate = DataService.poopRateBase(player)
	local owned = ToiletService.totalToilets(player)
	local refund, sold = 0, 0
	for i = #p.toilets, 1, -1 do
		local t = p.toilets[i]
		if (t.tier or 1) < p.buyTier then
			-- paid back at what that toilet costs to buy right now, so this is never a
			-- way to make money off the upgrade
			refund += Config.buyCostFor(t.tier, owned, rate)
			if plot then PlotService.clearToilet(plot, t.slot) end
			table.remove(p.toilets, i)
			sold += 1
		end
	end

	if sold > 0 then
		refund = math.floor(refund)
		p.cash += refund
		toast(
			player,
			("Sold %d stranded toilet%s for $%s"):format(sold, sold == 1 and "" or "s", Format.cash(refund)),
			"reward"
		)
	end

	DataService.push(player)
	Analytics.cashSpent(player, cost, p.cash, Enum.AnalyticsEconomyTransactionType.Shop, "BuyTier")
	if sold > 0 then
		Analytics.cashEarned(
			player,
			refund,
			p.cash,
			Enum.AnalyticsEconomyTransactionType.Gameplay,
			"StrandedToiletRefund"
		)
	end
	-- the tier is the value, so the dashboard shows how far up the ladder people get
	Analytics.custom(player, "BuyTierUpgraded", p.buyTier)
	return true
end

-- ── offline earnings ─────────────────────────────────────────────────────
function EconomyService.reportOffline(player: Player)
	local p = DataService.get(player)
	if not p then return end
	if p.lastLogout == 0 then return end -- first-ever join awards nothing

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
	local value = Config.offlinePoop(p.rateAtLogout or 0, away, hasPass)
	if value <= 0 then return end

	local items = Config.offlineItems(p.itemRateAtLogout or 0, away, hasPass)
	if items <= 0 then
		-- profiles saved before itemRateAtLogout existed only recorded the value rate.
		-- Divide by today's average poop value rather than paying zero items, which
		-- would leave the basket reading 0 after a claim.
		local rateNow, itemsNow = DataService.poopRate(player), DataService.poopItemRate(player)
		local avg = itemsNow > 0 and (rateNow / itemsNow) or 1
		items = math.max(1, math.floor(value / math.max(avg, 1)))
	end

	offlineOffer[player] = { value = value, items = items }
	offlineClaimed[player] = nil
	-- `poops` is the COUNT, because that is what the modal says and what the basket
	-- will show; `value` is what it banks.
	OfflineEvent:FireClient(player, {
		poops = items,
		value = value,
		seconds = math.min(away, hasPass and Config.OFFLINE_CAP_PASS or Config.OFFLINE_CAP),
	})
end

-- `doubled` is only ever passed by the DoubleOffline receipt handler, never by the
-- client. Claiming normally used to clear the offer outright, so a player who hit
-- Claim and then bought the x2 left the receipt with nothing to grant — it returned
-- nil, ProcessReceipt answered NotProcessedYet, and Roblox retried that forever.
-- The claimed amount is now remembered so the purchase can pay the missing half.
function EconomyService.claimOffline(player: Player, doubled: boolean?)
	local p = DataService.get(player)
	if not p then return end

	local grant: OfflineOffer?
	if doubled then
		local offer = offlineOffer[player]
		local claimed = offlineClaimed[player]
		if offer then
			-- bought before claiming: pay both halves at once
			grant = { value = offer.value * 2, items = offer.items * 2 }
		elseif claimed then
			-- already claimed at 1x: pay only the bonus half
			grant = claimed
		end
		-- either way the doubling is spent, so a second purchase cannot re-double
		offlineClaimed[player] = nil
	else
		grant = offlineOffer[player]
		if grant then offlineClaimed[player] = grant end
	end

	offlineOffer[player] = nil
	-- Nothing outstanding. Returning falsy keeps ProcessReceipt on NotProcessedYet,
	-- which leaves the purchase uncharged rather than taking Robux for nothing.
	if not grant or grant.value <= 0 then return end

	-- Credit BOTH halves. Adding only the value left the basket reading the same
	-- count it did before the claim, which is why claiming looked like it did nothing.
	-- There is no carry cap any more, so nothing here is clamped: the player still has
	-- to walk it to the Septic Tank, which is the point of paying out in poop.
	p.poops += grant.value
	p.poopItems += grant.items
	DataService.push(player, { poops = p.poops, poopItems = p.poopItems })
	-- Written out rather than `doubled and "x2" or "x1"`. That reads the same and
	-- is the pattern this codebase keeps getting caught by, so it does not go in
	-- even where it would happen to work.
	local kind
	if doubled then
		kind = "x2"
	else
		kind = "x1"
	end
	Analytics.custom(player, "OfflineClaim", grant.items, kind)
	return true
end

-- ── group reward pad ─────────────────────────────────────
-- Seconds until the pad can pay this player again; 0 means it is ready. The
-- cooldown is wall-clock in the profile, not os.clock(), so hopping servers does
-- not reset it.
function EconomyService.groupRewardCooldown(player: Player): number
	local p = DataService.get(player)
	if not p then return Config.GROUP_REWARD.cooldown end
	local now = os.time()
	local last = tonumber(p.lastGroupRewardAt) or 0
	if last <= 0 or last > now then return 0 end
	return math.max(0, Config.GROUP_REWARD.cooldown - (now - last))
end

-- The membership check belongs to the caller: the pad decides whether to pay out
-- or to raise the join prompt.
function EconomyService.groupReward(player: Player, worldPos: Vector3?)
	local p = DataService.get(player)
	if not p then return end

	local left = EconomyService.groupRewardCooldown(player)
	if left > 0 then
		toast(player, ("Group reward in %dm %ds"):format(left // 60, left % 60), "error")
		return
	end

	local amount = Config.groupReward(p.cash)
	p.lastGroupRewardAt = os.time()
	p.cash += amount
	DataService.push(player, { cash = p.cash })
	Analytics.cashEarned(
		player,
		amount,
		p.cash,
		Enum.AnalyticsEconomyTransactionType.TimedReward,
		"GroupReward"
	)
	CashEvent:FireClient(player, { amount = amount, pos = worldPos })
	toast(player, ("Thanks for joining! +%s"):format(Format.cash(amount)), "reward")
	if worldPos then require(script.Parent.VfxService).play("confetti", worldPos + Vector3.new(0, 2, 0)) end
	return amount
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
	Analytics.cashEarned(
		player,
		reward,
		p.cash,
		Enum.AnalyticsEconomyTransactionType.TimedReward,
		"FreeMoneyChest"
	)
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
	pending[player] = tonumber(p.pendingCash) or 0
	queuePoops[player] = tonumber(p.queuePoops) or 0
	queueItems[player] = tonumber(p.queueItems) or 0
	queueCash[player] = tonumber(p.queueCash) or 0
end

local function capture(player: Player, p)
	p.pendingCash = pending[player] or 0
	p.queuePoops = queuePoops[player] or 0
	p.queueItems = queueItems[player] or 0
	p.queueCash = queueCash[player] or 0
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
		queueItems[player] = nil
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
				-- The SETTING as well as the pass. This checked ownership alone, so the
				-- Settings toggle did nothing and cash kept collecting itself however it
				-- was set -- the poop loop had always checked both.
				local p = DataService.get(player)
				local wants = p ~= nil and p.settings.AutoCash == true
				if (pending[player] or 0) > 0 and wants and PassService.has(player, "AutoCash") then
					EconomyService.collectCash(player)
				end
			end
		end
	end)
end

return EconomyService
