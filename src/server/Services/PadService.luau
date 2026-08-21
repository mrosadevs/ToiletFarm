--!strict
-- PadService — every walk-on button in the world. Owns the touch dispatch and keeps
-- the billboard labels live (prices tick up as the player grows).

local Players = game:GetService("Players")
local CollectionService = game:GetService("CollectionService")
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

local COOLDOWN = {
	BuyButton = 1.0, MergePad = 0.5, DepositPad = 0.35, CollectCashPad = 0.25,
	RebirthPad = 1.0, FreeMoneyPad = 1.0, ProcessingPad = 0.4,
}
local DEFAULT_COOLDOWN = 0.6

local lastTouch: { [Player]: { [Model]: number } } = {}
local warned: { [Instance]: boolean } = {}

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

		-- color plate grey if unaffordable
		local plate = pad:FindFirstChild("Plate") :: BasePart?
		if plate then
			local can_afford = tier ~= nil and p.cash >= (unit * amount)
			plate.Color = can_afford and Color3.fromRGB(107, 79, 60) or Color3.fromRGB(110, 110, 118)
		end
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

		local plate = pad:FindFirstChild("Plate") :: BasePart?
		if plate then
			local can_afford = cost ~= nil and p.cash >= cost
			plate.Color = can_afford and Color3.fromRGB(107, 79, 60) or Color3.fromRGB(110, 110, 118)
		end

	elseif kind == "DepositPad" then
		if quantity then quantity.Text = ("Deposit %s Poops"):format(Format.short(p.poops)) end
	elseif kind == "RebirthPad" then
		local cost = Config.rebirthCost(p.rebirths)
		if quantity then quantity.Text = cost and ("Rebirth %d"):format(p.rebirths + 1) or "MAX REBIRTH" end
		if price then price.Text = cost and ("$" .. Format.cash(cost)) or "" end

		local plate = pad:FindFirstChild("Plate") :: BasePart?
		if plate then
			local can_afford = cost ~= nil and p.cash >= cost
			plate.Color = can_afford and Color3.fromRGB(107, 79, 60) or Color3.fromRGB(110, 110, 118)
		end
	elseif kind == "UpgradeBuyTierPad" then
		local tier = p.buyTier or 1
		local ceiling = Config.maxBuyTier(p.rebirths)
		local plate = pad:FindFirstChild("Plate") :: BasePart?
		if tier >= ceiling then
			if quantity then quantity.Text = "Upgrade Buy Tier" end
			if price then price.Text = ("[REQ: Rebirth %d]"):format(p.rebirths + 1) end
			if plate then plate.Color = Color3.fromRGB(110, 110, 118) end
		else
			if quantity then
				quantity.Text = ("Upgrade Buy Tier\n%s > %s")
					:format(Config.displayName(tier), Config.displayName(tier + 1))
			end
			local need = Config.buyTierRequirement(tier)
			local owned = ToiletService.totalToilets(player)
			local can_afford = owned >= need
			if price then
				price.Text = can_afford
					and ("$" .. Format.cash(Config.buyTierCost(tier)))
					or ("%s / %s Toilets"):format(Format.short(owned), Format.short(need))
			end
			if plate then
				plate.Color = can_afford and Color3.fromRGB(107, 79, 60) or Color3.fromRGB(110, 110, 118)
			end
		end
	elseif kind == "MergePad" then
		if quantity then quantity.Text = "Merge All" end
		if price then price.Text = "" end
	elseif kind == "FreeMoneyPad" then
		-- no hologram: this pad has its own FreeMoneySign board, and the billboard
		-- floated high above the septic area where it read as a stray label
	end

	-- Robux-priced pads: the hologram number comes from the live product price,
	-- never from the mockup value baked into the model.
	local robux = ROBUX_PADS[kind]
	if robux then
		local isPass = robux.kind == "pass"
		-- the buyer price, not GetProductInfo's creator-set value
		local robuxPrice = isPass
			and Prices.pass(robux.id)
			or Prices.product(robux.id)
		local exists = isPass
			and PassService.passId(robux.id) ~= 0
			or PassService.productId(robux.id) ~= 0

		if quantity then
			local owned = isPass and PassService.has(player, robux.id)
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

handlers.GroupJoinPad = function(player)
	-- Fire client event to prompt group join
	local groupId = 16284220
	Net.event(Net.NAMES.Toast):FireClient(player, "Opening group page...", "info")
	task.wait(0.5)
	-- Use game:GetService("GuiService") to open group (needs client execution)
	-- For now, toast tells them to join manually
	Net.event(Net.NAMES.Toast):FireClient(player, "Join our group: roblox.com/groups/" .. groupId, "info")
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

	plate.Touched:Connect(function(hit)
		local player = playerFromPart(hit)
		if not player then return end
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

function PadService.init()
	-- PadTouch is a tall invisible volume above each plate; the plates themselves are
	-- barely 0.15 studs thick and flush with the ground, so walking over one does not
	-- reliably fire Touched on its own.
	for _, zone in ipairs(CollectionService:GetTagged("PadTouch")) do
		bindPlate(zone)
	end
	CollectionService:GetInstanceAddedSignal("PadTouch"):Connect(bindPlate)

	task.spawn(PadService.runSellZone)

	Players.PlayerRemoving:Connect(function(player) lastTouch[player] = nil end)

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
