--!strict
-- PadService — every walk-on button in the world. Owns the touch dispatch and keeps
-- the billboard labels live (prices tick up as the player grows).

local Players = game:GetService("Players")
local CollectionService = game:GetService("CollectionService")
local ServerStorage = game:GetService("ServerStorage")
local MarketplaceService = game:GetService("MarketplaceService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.ToiletConfig)
local Format = require(Shared.Format)
local Net = require(Shared.Net)
local Prices = require(Shared.Prices)

local DataService     = require(script.Parent.DataService)
local PlotService     = require(script.Parent.PlotService)
local ToiletService   = require(script.Parent.ToiletService)
local EconomyService  = require(script.Parent.EconomyService)
local PassService     = require(script.Parent.PassService)
local TutorialService = require(script.Parent.TutorialService)

local PadService = {}

-- Bound at module scope, not inside the handler: Net creates a remote on the server
-- the first time it is asked for one, so a remote only referenced inside a touch
-- handler does not exist until someone steps on the pad -- and the client, which
-- connects at startup, times out waiting for it.
local GroupJoinEvent = Net.event(Net.NAMES.PromptGroupJoin)

-- The group that owns this place. Read from game.CreatorId rather than pasted in,
-- so it cannot drift if the game is ever moved to another group.
local GROUP_ID = (game.CreatorType == Enum.CreatorType.Group) and game.CreatorId or 0

-- Player:IsInGroup is answered from a snapshot taken when the player joined, so
-- someone who accepts the prompt mid-session still reads as a non-member. A web
-- refresh fixes that, but it is a web call: only the touch handler may ask for
-- one, the label refresh reads the cache, and a miss is not retried for RECHECK
-- seconds.
local RECHECK = 20
local groupCache: { [Player]: { member: boolean, at: number } } = {}

local function isGroupMember(player: Player, allowRefresh: boolean?): boolean
	if GROUP_ID == 0 then return false end
	local cached = groupCache[player]
	if cached and cached.member then return true end
	if player:IsInGroup(GROUP_ID) then
		groupCache[player] = { member = true, at = os.clock() }
		return true
	end
	if not allowRefresh then return false end
	if cached and os.clock() - cached.at < RECHECK then return false end

	local member = false
	local ok, groups = pcall(function()
		return game:GetService("GroupService"):GetGroupsAsync(player.UserId)
	end)
	if ok and type(groups) == "table" then
		for _, g in ipairs(groups) do
			if g.Id == GROUP_ID then member = true break end
		end
	end
	groupCache[player] = { member = member, at = os.clock() }
	return member
end

-- A floor under deliberate re-steps only; the real once-per-step guard is the
-- contact counting in bindPlate.
local COOLDOWN = {
	BuyButton = 0.25, MergePad = 0.5, DepositPad = 0.35, CollectCashPad = 0.25,
	RebirthPad = 1.0, FreeMoneyPad = 1.0, ProcessingPad = 0.4,
}
local DEFAULT_COOLDOWN = 0.6

local lastTouch: { [Player]: { [Model]: number } } = {}
local warned: { [Instance]: boolean } = {}
-- who is currently standing on each plate: plate -> player -> contact count
local occupancy: { [BasePart]: { [Player]: number } } = {}

local function onCooldown(player: Player, pad: Model): boolean
	local kind = pad:GetAttribute("PadKind")
	local cd = COOLDOWN[kind] or DEFAULT_COOLDOWN
	lastTouch[player] = lastTouch[player] or {}
	local last = lastTouch[player][pad]
	local now = os.clock()
	if last and now - last < cd then return true end
	lastTouch[player][pad] = now
	return false
end

-- ── label refresh ────────────────────────────────────────────────────────
-- `SubLabel` is the small grey caption above the main one on pads that have two
-- (the Buy 100 pad's "(Auto Merge)"). It used to be a second label also called
-- Quantity, so this loop overwrote it and the pad read "Buy 100 Toilets" twice.
local function labels(pad: Model): (TextLabel?, TextLabel?, TextLabel?)
	local quantity, price, sub
	for _, d in ipairs(pad:GetDescendants()) do
		if d:IsA("TextLabel") then
			if d.Name == "Quantity" then quantity = d
			elseif d.Name == "Price" then price = d
			elseif d.Name == "SubLabel" then sub = d end
		end
	end
	return quantity, price, sub
end

-- A pad has to read as one of three things from across the farm:
--   ready     the pad's own colour -- green to buy, yellow to merge, purple to upgrade
--   denied    red: the action is live but you cannot pay for it yet
--   inactive  grey: nothing to do here at all -- maxed out, locked behind a rebirth,
--             or, on the Merge pad, nothing to act on
-- Unaffordable used to share the grey with maxed-out, so a pad you had simply
-- outgrown and one you were two dollars short of looked identical.
--
-- The BUTTON is what changes colour. `Plate` is the brown wooden base every pad
-- stands on, and repainting that turned the whole pad into a slab of colour. Each
-- button also has its OWN authored colour, so there is no single "ready" shade to
-- return to: the original is stashed on the part the first time it is seen and put
-- back from there.
local PAD = { ready = "ready", denied = "denied", inactive = "inactive" }
local DENIED = Color3.fromRGB(178, 52, 52)
local INACTIVE = Color3.fromRGB(110, 110, 118)

local function paint(pad: Model, state: string)
	local button = pad:FindFirstChild("Part") :: BasePart?
	if not button then return end

	local authored = button:GetAttribute("ReadyColor")
	if typeof(authored) ~= "Color3" then
		-- first sight, before anything has been overridden
		authored = button.Color
		button:SetAttribute("ReadyColor", authored)
	end

	local want = (state == PAD.denied and DENIED)
		or (state == PAD.inactive and INACTIVE)
		or authored
	-- guarded: this runs 4x a second per pad, and an unchanged write still replicates
	if button.Color ~= want then button.Color = want end
end

-- pads that sell a gamepass or dev product, and which one
local ROBUX_PADS = {
	AutoPoopPad  = { kind = "pass",    id = "AutoFlush",        label = "Auto Collect Poops" },
	AutoCashPad  = { kind = "pass",    id = "AutoCash",         label = "Auto Collect Cash"  },
	FinishNowPad = { kind = "product", id = "FinishProcessing", label = "Finish Now"         },
}

local function refreshPad(pad: Model, player: Player)
	local kind = pad:GetAttribute("PadKind")
	local quantity, price, sub = labels(pad)
	local p = DataService.get(player)
	if not p then return end

	if kind == "BuyButton" then
		local amount = pad:GetAttribute("BuyAmount") or 1
		local tier, unit = ToiletService.buyPreview(player, amount)
		if quantity then
			quantity.Text = amount == 1 and "Buy 1 Toilet" or ("Buy %d Toilets"):format(amount)
		end
		-- the bulk pad doubles as Auto Merge; say so on its sub-caption
		if sub then sub.Text = amount >= 100 and "(Auto Merge)" or "" end
		if price then price.Text = "$" .. Format.cash(unit * amount) end
		pad:SetAttribute("PreviewTier", tier)

		-- this pad always has something to sell, so the only failure is the price
		paint(pad, (tier ~= nil and p.cash >= unit * amount) and PAD.ready or PAD.denied)
	elseif kind == "CollectCashPad" then
		if quantity then quantity.Text = "Collect Cash" end
		if price then price.Text = "$" .. Format.cash(EconomyService.pendingCash(player)) end
	elseif kind == "ProcessingPad" then
		-- upgrades how fast the deposited queue sells, not the drop rate
		local level = p.processing or 0
		-- show the real gain, which is dominated by the production-scaled floor,
		-- not the raw config curve
		local now = EconomyService.processRate(player)
		local produced = DataService.poopRate(player)
		local nxt = math.max(Config.processRate(level + 1), produced * (2 + level))
		if quantity then quantity.Text = ("+%s Per Second"):format(Format.short(math.max(0, nxt - now))) end
		local cost = Config.processCost(level)
		if price then price.Text = cost and ("$" .. Format.cash(cost)) or "MAX" end

		if cost == nil then
			paint(pad, PAD.inactive) -- fully upgraded, not too expensive
		else
			paint(pad, p.cash >= cost and PAD.ready or PAD.denied)
		end

	elseif kind == "DepositPad" then
		-- items, matching the basket gauge and the "Deposited X Poops!" banner; this
		-- used to quote p.poops (the cash value), so the three disagreed
		if quantity then quantity.Text = ("Deposit %s Poops"):format(Format.short(p.poopItems)) end
	elseif kind == "RebirthPad" then
		local cost = Config.rebirthCost(p.rebirths)
		if quantity then quantity.Text = cost and ("Rebirth %d"):format(p.rebirths + 1) or "MAX REBIRTH" end
		if price then price.Text = cost and ("$" .. Format.cash(cost)) or "" end

		if cost == nil then
			paint(pad, PAD.inactive) -- MAX REBIRTH
		else
			paint(pad, p.cash >= cost and PAD.ready or PAD.denied)
		end
	elseif kind == "UpgradeBuyTierPad" then
		local tier = p.buyTier or 1
		local ceiling = Config.maxBuyTier(p.rebirths)
		if tier >= ceiling then
			if quantity then quantity.Text = "Upgrade Buy Tier" end
			if price then price.Text = ("[REQ: Rebirth %d]"):format(p.rebirths + 1) end
			paint(pad, PAD.inactive) -- no amount of cash opens this until you rebirth
		else
			if quantity then
				quantity.Text = ("Upgrade Buy Tier\n%s > %s")
					:format(Config.displayName(tier), Config.displayName(tier + 1))
			end
			local need = Config.buyTierRequirement(tier)
			local owned = ToiletService.totalToilets(player)
			local cost = Config.buyTierCost(tier)
			local hasToilets = owned >= need
			if price then
				price.Text = hasToilets
					and ("$" .. Format.cash(cost))
					or ("%s / %s Toilets"):format(Format.short(owned), Format.short(need))
			end
			-- it costs toilets AND cash, and either shortfall is "you cannot buy this yet"
			paint(pad, (hasToilets and p.cash >= cost) and PAD.ready or PAD.denied)
		end
	elseif kind == "GroupJoinPad" then
		-- Reads the membership CACHE only. Refreshing it is a web call and this runs
		-- four times a second.
		if not isGroupMember(player) then
			if quantity then quantity.Text = "Join The Group" end
			if price then price.Text = "Free Cash!" end
			paint(pad, PAD.inactive)
		else
			local left = EconomyService.groupRewardCooldown(player)
			if quantity then quantity.Text = "Group Reward" end
			if price then
				price.Text = left > 0
					and ("Ready in %d:%02d"):format(left // 60, left % 60)
					or ("$" .. Format.cash(Config.groupReward(p.cash)))
			end
			paint(pad, left > 0 and PAD.inactive or PAD.ready)
		end
	elseif kind == "MergePad" then
		if quantity then quantity.Text = "Merge All" end
		if price then price.Text = "" end
		-- Grey with nothing to merge. Stepping on it in that state can only ever
		-- produce the "you need 3 of a kind" toast, so say so before the player walks.
		paint(pad, ToiletService.pendingMerges(player) > 0 and PAD.ready or PAD.inactive)
	elseif kind == "FreeMoneyPad" then
		-- no hologram: this pad has its own FreeMoneySign board, and the billboard
		-- floated high above the septic area where it read as a stray label
	end

end

-- A Robux price is the same number for everybody, so these pads are refreshed on
-- EVERY plot rather than only the one its owner is standing on. refreshPad runs for
-- the owner alone, which left every unclaimed farm advertising the mockup figures
-- baked into the models -- 64 for Auto Collect Poops, 24 for Auto Collect Cash,
-- 16 for Instant Poop Process, against real prices of 67, 25 and 15.
local function refreshRobuxPad(pad: Model, owner: Player?)
	local robux = ROBUX_PADS[pad:GetAttribute("PadKind")]
	if not robux then return end
	local quantity, price = labels(pad)
	local isPass = robux.kind == "pass"
	-- the buyer price, not GetProductInfo's creator-set value
	local robuxPrice = isPass and Prices.pass(robux.id) or Prices.product(robux.id)
	local exists = isPass
		and PassService.passId(robux.id) ~= 0
		or PassService.productId(robux.id) ~= 0

	if quantity then
		local owned = isPass and owner ~= nil and PassService.has(owner, robux.id)
		quantity.Text = owned and (robux.label .. " ✓") or robux.label
	end
	if price then
		if robuxPrice then
			price.Text = tostring(robuxPrice)
		elseif not exists then
			price.Text = "soon"
		end
		-- if the product exists but the async price hasn't landed yet, leave the
		-- label as-is rather than flashing a wrong number
	end
end

-- The "Selling Poop… / N per second" board over the processing area.
local function refreshSellingSign(plot: Model, player: Player)
	local sign = plot:FindFirstChild("FlushMeterSign", true)
	if not sign then return end
	local queued = EconomyService.queued(player)
	local friends = EconomyService.friendsInServer(player)
	for _, d in ipairs(sign:GetDescendants()) do
		if d:IsA("TextLabel") then
			if d.Name == "Amount" then
				d.Text = Format.short(queued)
			elseif d.Name == "PerSecond" then
				d.Text = Format.short(EconomyService.processRate(player)) .. " per second"
			elseif d.Name == "FriendBoost" then
				d.Text = friends > 0
					and ("(+%d%% Friend Boost)"):format(math.floor(math.min(friends * Config.PROCESSING.friendBoost, Config.PROCESSING.maxFriendBoost) * 100))
					or "(No Friend Boost)"
			elseif d.Name == "Header" then
				d.Text = queued > 0 and "Selling Poop..." or "Nothing Selling"
			end
		end
	end
end

-- ── dispatch ───────────────────────────────────────────────────────────
local handlers: { [string]: (Player, Model) -> () } = {}

handlers.BuyButton = function(player, pad)
	local amount = pad:GetAttribute("BuyAmount") or 1
	local bought = ToiletService.buy(player, amount)
	if bought and bought > 0 then
		TutorialService.notify(player, "buy", bought)
		TutorialService.syncCounts(player)
		-- The bulk pad doubles as Auto Merge. Buying stops as soon as slots run
		-- out, so merge and keep buying until the full amount is placed, the cash
		-- runs out, or a pass makes no further progress.
		if amount >= 100 then
			local placed = bought
			for _ = 1, 40 do
				if placed >= amount then break end
				ToiletService.mergeAll(player)
				local more = ToiletService.buy(player, amount - placed)
				if not more or more <= 0 then break end
				placed += more
			end
			ToiletService.mergeAll(player)
			TutorialService.syncCounts(player)
		end
	end
end

handlers.UpgradeBuyTierPad = function(player)
	EconomyService.upgradeBuyTier(player)
end

handlers.MergePad = function(player)
	local n = ToiletService.mergeAll(player)
	if n and n > 0 then TutorialService.notify(player, "merge", 1) end
end

handlers.DepositPad = function(player)
	local poops = EconomyService.deposit(player)
	if poops and poops > 0 then TutorialService.notify(player, "deposit", 1) end
end

handlers.CollectCashPad = function(player, pad)
	local pos = pad.PrimaryPart and pad.PrimaryPart.Position
	local amount = EconomyService.collectCash(player, pos)
	if amount and amount > 0 then TutorialService.notify(player, "cash", 1) end
end

handlers.RebirthPad = function(player)
	Net.event(Net.NAMES.Toast):FireClient(player, "__OPEN_REBIRTH", "ui")
end

handlers.ProcessingPad = function(player)
	EconomyService.buyProcessing(player)
end

handlers.FreeMoneyPad = function(player)
	EconomyService.freeMoney(player)
end

-- "Finish Now": skip the remaining selling queue for Robux
handlers.FinishNowPad = function(player)
	local queued = EconomyService.queued(player)
	if queued <= 0 then
		Net.event(Net.NAMES.Toast):FireClient(player, "Nothing is processing!", "error")
		return
	end
	local id = PassService.productId("FinishProcessing")
	if id == 0 then
		-- product not created yet: let it through so the mechanic is testable
		EconomyService.finishProcessing(player)
		return
	end
	player:SetAttribute("PendingFinishNow", true)
	MarketplaceService:PromptProductPurchase(player, id)
end

-- Members collect cash here every ten minutes. Everyone else gets the join prompt
-- and nothing else -- the reward is the reason to join, so it cannot pay out first.
handlers.GroupJoinPad = function(player, pad)
	if GROUP_ID == 0 then
		Net.event(Net.NAMES.Toast):FireClient(player, "No group set up yet!", "error")
		return
	end
	if not isGroupMember(player, true) then
		-- GroupService:PromptJoinAsync only exists on the client, so ask the client to
		-- raise it rather than trying to prompt from here.
		GroupJoinEvent:FireClient(player, GROUP_ID)
		Net.event(Net.NAMES.Toast):FireClient(player, "Join the group to collect this!", "info")
		return
	end
	local plate = pad:FindFirstChild("Plate") :: BasePart?
	EconomyService.groupReward(player, plate and plate.Position)
end

local function promptPass(passName: string)
	return function(player: Player)
		local id = PassService.passId(passName)
		if id == 0 then
			Net.event(Net.NAMES.Toast):FireClient(player, "Coming soon!", "error")
			return
		end
		if PassService.has(player, passName) then
			Net.event(Net.NAMES.Toast):FireClient(player, "You already own this!", "info")
			return
		end
		MarketplaceService:PromptGamePassPurchase(player, id)
	end
end

handlers.AutoPoopPad  = promptPass("AutoFlush")
handlers.AutoCashPad  = promptPass("AutoCash")
handlers.AutoMergePad = promptPass("AutoMerge")

-- ── wiring ──────────────────────────────────────────────────────────────
local function playerFromPart(part: BasePart): Player?
	local char = part.Parent
	if not char then return nil end
	local humanoid = char:FindFirstChildOfClass("Humanoid")
	if not humanoid then return nil end
	return Players:GetPlayerFromCharacter(char)
end

local function bindPlate(plate: BasePart)
	if plate:GetAttribute("PadBound") then return end
	plate:SetAttribute("PadBound", true)
	local pad = plate.Parent
	while pad and not pad:GetAttribute("PadKind") do pad = pad.Parent end
	if not pad then return end
	local padModel = pad :: Model

	-- Every pad is a discrete action, so it must fire once per step-on, not once per
	-- limb per contact. A character lands on a plate with both legs (and re-touches
	-- as it settles), which is why "Buy 1 Toilet" was buying two. Count how many of
	-- the player's parts are in contact and only act on the 0 -> 1 transition.
	local contacts: { [Player]: number } = {}
	occupancy[plate] = contacts

	plate.Touched:Connect(function(hit)
		local player = playerFromPart(hit)
		if not player then return end
		local n = contacts[player] or 0
		contacts[player] = n + 1
		if n > 0 then return end -- already standing on it

		-- pads only work on your own plot
		local plot = PlotService.plotOfInstance(padModel)
		if plot and PlotService.plotFor(player) ~= plot then return end
		if onCooldown(player, padModel) then return end

		local kind = padModel:GetAttribute("PadKind") :: string
		local handler = handlers[kind]
		if handler then
			task.spawn(handler, player, padModel)
		end
	end)

	plate.TouchEnded:Connect(function(hit)
		local player = playerFromPart(hit)
		if not player then return end
		local n = (contacts[player] or 0) - 1
		contacts[player] = n > 0 and n or nil
	end)
end

-- ── the Sell area ────────────────────────────────────────────────────────
-- Depositing is a zone, not a button: stand in the glow and poop drains out.
-- The glow reports what is happening — green while banking, red when you have
-- nothing left, blue when idle.
local SELL_GLOW = {
	idle  = Color3.fromRGB(  9, 158, 222),
	ok    = Color3.fromRGB( 60, 220,  70),
	empty = Color3.fromRGB(230,  60,  60),
}

local function sellParts(plot: Model): (BasePart?, BasePart?)
	local sell = plot:FindFirstChild("Sell", true)
	if not sell then return nil, nil end
	local glow, zone
	for _, d in ipairs(sell:GetDescendants()) do
		if d:IsA("BasePart") then
			if not glow and d.Material == Enum.Material.Neon then glow = d end
			if not zone and d.Name == "TouchZone" then zone = d end
		end
	end
	return glow, zone
end

local function insideZone(zone: BasePart, pos: Vector3): boolean
	local rel = zone.CFrame:PointToObjectSpace(pos)
	local h = zone.Size / 2
	return math.abs(rel.X) <= h.X and math.abs(rel.Y) <= h.Y and math.abs(rel.Z) <= h.Z
end

function PadService.runSellZone()
	while true do
		task.wait(0.2)
		for _, player in ipairs(Players:GetPlayers()) do
			local ok = pcall(function()
				local plot = PlotService.plotFor(player)
				local p = DataService.get(player)
				if not plot or not p then return end
				local glow, zone = sellParts(plot)
				if not glow or not zone then return end

				local char = player.Character
				local hrp = char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
				local state = "idle"
				if hrp and insideZone(zone, hrp.Position) then
					if p.poops > 0 then
						local banked = EconomyService.deposit(player)
						if banked and banked > 0 then
							TutorialService.notify(player, "deposit", 1)
						end
						state = "ok"
					else
						state = "empty"
					end
				end
				local want = SELL_GLOW[state]
				if glow.Color ~= want then glow.Color = want end
			end)
		end
	end
end

-- Where each plot's Rebirth and Group pads belong, in the plot's own frame.
--
-- The first version of this derived the group pad's spot from "whichever group pad
-- is nearest its own plot" -- and on Plot1 that pad IS the plot's rebirth pad, which
-- the owner had renamed into a group pad. So every other plot got a group pad
-- dropped exactly on top of its rebirth pad, and standing there fired both: the
-- reward toast AND the rebirth panel. That is the bug the partner screenshotted.
--
-- The rebirth pad is the anchor now, and the group pad sits a clear 12 studs off it
-- (their touch volumes are 6-7 studs across, so that cannot overlap). Plot1 is also
-- given its rebirth pad back, since renaming it left that farm with no way to
-- rebirth from the world at all.
local GROUP_PAD_OFFSET = Vector3.new(0, 0, -12)

local function padOfKind(plot: Instance, kind: string): Model?
	for _, d in ipairs(plot:GetDescendants()) do
		if d:IsA("Model") and d:GetAttribute("PadKind") == kind then return d end
	end
	return nil
end

local function seatPlotPads()
	local plots = workspace:FindFirstChild("Plots")
	if not plots then return end

	-- the canonical rebirth placement, taken from any plot that still has one
	local rebirthRel: CFrame? = nil
	for _, plot in ipairs(plots:GetChildren()) do
		local pad = plot:IsA("Model") and padOfKind(plot, "RebirthPad")
		if pad then
			rebirthRel = plot:GetPivot():ToObjectSpace(pad:GetPivot())
			break
		end
	end
	if not rebirthRel then
		warn("[PadService] no RebirthPad anywhere -- pads left where they are")
		return
	end

	local template = ServerStorage:FindFirstChild("Assets")
	template = template and template:FindFirstChild("PlotTemplate")
	local rebirthSource = template and padOfKind(template, "RebirthPad")

	for _, plot in ipairs(plots:GetChildren()) do
		if plot:IsA("Model") then
			local pivot = plot:GetPivot()

			local rebirth = padOfKind(plot, "RebirthPad")
			if not rebirth and rebirthSource then
				rebirth = rebirthSource:Clone()
				rebirth.Parent = plot:FindFirstChild("Base") or plot
				print(("[PadService] %s had no RebirthPad -- restored one"):format(plot.Name))
			end
			if rebirth then
				rebirth:PivotTo(pivot * (rebirthRel :: CFrame))
			end

			local group = padOfKind(plot, "GroupJoinPad")
			if group then
				group:PivotTo(pivot * ((rebirthRel :: CFrame) + GROUP_PAD_OFFSET))
			end
		end
	end
end

-- Two pads were authored with no billboard at all, so they had nothing to say:
-- the group pad, and Upgrade Buy Tier -- which refreshPad has been computing text
-- for all along and throwing away. Clone the board off a neighbouring pad on the
-- same plot rather than building one from scratch, so it matches the farm exactly.
local function ensureBillboard(pad: Model, seedQuantity: string, seedPrice: string)
	for _, d in ipairs(pad:GetDescendants()) do
		if d:IsA("BillboardGui") then return end
	end
	local plots = workspace:FindFirstChild("Plots")
	local plot = pad.Parent
	while plot and plot.Parent ~= plots do plot = plot.Parent end
	if not plot then return end

	-- Prefer one specific neighbour: whichever Text attachment turns up first varies
	-- from plot to plot (a DepositPad on one, a BuyButton on another), and the group
	-- pad should look the same on every farm.
	local donor: Attachment? = nil
	local fallback: Attachment? = nil
	for _, d in ipairs(plot:GetDescendants()) do
		if d:IsA("Attachment") and d.Name == "Text" and d:FindFirstChildOfClass("BillboardGui") then
			local owner = d:FindFirstAncestorOfClass("Model")
			if owner and owner:GetAttribute("PadKind") == "CollectCashPad" then
				donor = d
				break
			end
			fallback = fallback or d
		end
	end
	donor = donor or fallback
	local host = pad:FindFirstChild("Part") or pad:FindFirstChild("Plate")
	if not donor or not host or not host:IsA("BasePart") then return end

	local copy = donor:Clone()
	local sub = copy:FindFirstChild("SubLabel", true)
	if sub then sub:Destroy() end
	-- Seed the labels: refreshPad only runs on a plot that has an owner, so an empty
	-- farm would otherwise advertise whatever the donor pad happened to say last.
	local q = copy:FindFirstChild("Quantity", true)
	if q and q:IsA("TextLabel") then q.Text = seedQuantity end
	local pr = copy:FindFirstChild("Price", true)
	if pr and pr:IsA("TextLabel") then pr.Text = seedPrice end
	copy.Parent = host
end

function PadService.init()
	seatPlotPads()
	local SEED = {
		GroupJoinPad = { "Group Reward", "Join The Group" },
		UpgradeBuyTierPad = { "Upgrade Buy Tier", "" },
	}
	for _, pad in ipairs(CollectionService:GetTagged("Pad")) do
		local seed = pad:IsA("Model") and SEED[pad:GetAttribute("PadKind")]
		if seed then ensureBillboard(pad, seed[1], seed[2]) end
	end

	-- PadTouch is a tall invisible volume above each plate; the plates themselves are
	-- barely 0.15 studs thick and flush with the ground, so walking over one does not
	-- reliably fire Touched on its own.
	for _, zone in ipairs(CollectionService:GetTagged("PadTouch")) do
		bindPlate(zone)
	end
	CollectionService:GetInstanceAddedSignal("PadTouch"):Connect(bindPlate)

	task.spawn(PadService.runSellZone)

	Players.PlayerRemoving:Connect(function(player)
		lastTouch[player] = nil
		groupCache[player] = nil
		for _, contacts in pairs(occupancy) do contacts[player] = nil end
	end)

	-- A dropped TouchEnded (respawn, ragdoll, teleport off the pad) would otherwise
	-- leave the count above zero and the pad dead for the rest of the session, so
	-- clear anyone who is demonstrably no longer standing on the plate.
	task.spawn(function()
		while true do
			task.wait(1)
			for plate, contacts in pairs(occupancy) do
				if not plate.Parent then
					occupancy[plate] = nil
					continue
				end
				local reach = plate.Size.Magnitude * 0.5 + 10
				for player in pairs(contacts) do
					local char = player.Character
					local hrp = char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
					if not hrp or (hrp.Position - plate.Position).Magnitude > reach then
						contacts[player] = nil
					end
				end
			end
		end
	end)

	-- Robux pads on every plot, owned or not. Slower than the owner loop because
	-- nothing on them changes except the ✓ when a pass is bought.
	task.spawn(function()
		while true do
			for _, plot in ipairs(workspace.Plots:GetChildren()) do
				local owner = PlotService.ownerOfPlot(plot)
				for _, d in ipairs(plot:GetDescendants()) do
					if d:IsA("Model") and ROBUX_PADS[d:GetAttribute("PadKind")] then
						pcall(refreshRobuxPad, d, owner)
					end
				end
			end
			task.wait(2)
		end
	end)

	-- keep every label on the owner's plot current, including the "Selling Poop…" sign
	task.spawn(function()
		while true do
			task.wait(0.25)
			for _, player in ipairs(Players:GetPlayers()) do
				local plot = PlotService.plotFor(player)
				local p = DataService.get(player)
				if not plot or not p then continue end
				for _, d in ipairs(plot:GetDescendants()) do
					if d:IsA("Model") and d:GetAttribute("PadKind") then
						-- One pad throwing used to kill this whole loop, which left every
						-- billboard stuck on its baked mockup text ("Auto Collect / 64").
						local ok, err = pcall(refreshPad, d, player)
						if not ok and not warned[d] then
							warned[d] = true
							warn(("[PadService] refresh failed for %s (%s): %s")
								:format(d.Name, tostring(d:GetAttribute("PadKind")), tostring(err)))
						end
					end
				end
				refreshSellingSign(plot, player)
			end
		end
	end)
end

return PadService
