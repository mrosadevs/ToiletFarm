--!strict
-- Hud — drives the always-on HUD: cash, basket, rebirth counter, toilet count,
-- the Flush Meter readout, and the gain chips down the left edge.

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.ToiletConfig)
local Format = require(Shared.Format)
local Net = require(Shared.Net)
local Prices = require(Shared.Prices)

local MarketplaceService = game:GetService("MarketplaceService")

local UIKit = require(script.Parent.UIKit)
local Audio = require(script.Parent.Audio)
local State = require(script.Parent.State)
local Screens = require(script.Parent.Screens)

-- must match PassService.PRODUCTS on the server
local PRODUCT_IDS = { 3708565222, 3708565345, 3708565384 }
-- must match PassService.PASSES.DoubleCash
local PASS_DOUBLE_CASH = 1948365646
-- must match the "if hasPass DoubleCash then m *= 2" in DataService.cashMultiplier
local DOUBLE_CASH_MULT = 2

local player = Players.LocalPlayer
local gui = player:WaitForChild("PlayerGui")

local Hud = {}

local screen: ScreenGui
local C: Frame
local lastCash = 0

local function find(name: string): any
	return C and C:FindFirstChild(name, true)
end

-- ── cash pack buttons ────────────────────────────────────────────────────
-- The three green chips down the left edge are the small/medium/large cash packs.
-- What each one advertises scales with the player's balance, so the label has to
-- be recomputed on every cash change rather than baked in.
local packs: { Frame } = {}

local function collectPacks()
	packs = {}
	for _, c in ipairs(C:GetChildren()) do
		if c:IsA("Frame") and c.Name == "CashGainChip" then table.insert(packs, c) end
	end
	-- Top to bottom = small, medium, large. This reads the AUTHORED offsets, so it
	-- has to run before UIKit.pinEdges re-anchors these to the bottom edge and the
	-- offsets stop being a screen ordering.
	table.sort(packs, function(a, b) return a.Position.Y.Offset < b.Position.Y.Offset end)

	for index, chip in ipairs(packs) do
		chip.Name = "CashPack" .. index
		UIKit.makeInteractive(chip, function()
			Audio.play("UiClick")
			local id = PRODUCT_IDS[index]
			if not id or id == 0 then
				require(script.Parent.Popups).toast("Coming soon!", "error")
				return
			end
			MarketplaceService:PromptProductPurchase(player, id)
		end, {
			hover = 1.08,
			onHover = function() Audio.play("UiHover", { volume = 0.4 }) end,
		})
	end
end

local function refreshPacks(cash: number)
	for index, chip in ipairs(packs) do
		local label = chip:FindFirstChild("GainLabel", true) :: TextLabel?
		if label then
			label.Text = "+" .. Format.cash(Config.cashPackAmount(cash, index)) .. "$"
		end
	end
end

-- ── refresh ────────────────────────────────────────────────────────────
local function refresh(data: any, changed: any)
	local cashLabel = find("CashAmount") :: TextLabel?
	if cashLabel then
		if changed.cash and data.cash ~= lastCash then
			-- a drop in balance is the one reliable signal that something was bought,
			-- and it catches every spend path (toilets, upgrades, buy tier, lucky unlock)
			if data.cash < lastCash then Audio.play("MoneySpend", { volume = 0.7 }) end
			UIKit.rollNumber(cashLabel, lastCash, data.cash, function(v) return "$" .. Format.cash(v) end)
			UIKit.pop(cashLabel, 1.15)
			lastCash = data.cash
		elseif not changed.cash then
			cashLabel.Text = "$" .. Format.cash(data.cash)
		end
	end
	refreshPacks(data.cash)

	-- How many poops you are carrying. There is no cap any more, so this is a plain
	-- count -- not the accumulated cash value, which is what made a basket reading
	-- "1.72K" bank as "Deposited 60 Poops!" and look like the game ate the difference.
	local poops = find("PoopsAmount") :: TextLabel?
	if poops then
		poops.Text = Format.short(data.poopItems or 0)
		if changed.poopItems or changed.poops then UIKit.pop(poops, 1.12) end
	end

	local poopsTitle = find("PoopsTitle") :: TextLabel?
	if poopsTitle then
		poopsTitle.Text = "Poops"
		poopsTitle.TextColor3 = Color3.new(1, 1, 1)
	end

	local rebirth = find("RebirthCounter") :: TextLabel?
	if rebirth then rebirth.Text = "Rebirth " .. tostring(data.rebirths) end

	-- Counts merge-equivalents, not stalls: a Tier 4 toilet took 3^3 = 27 Tier 1s
	-- to build, so it counts as 27. That is why the reference game can read
	-- "Total Chickens: 29" while only three are standing on the farm.
	local total = find("TotalToilets") :: TextLabel?
	if total then
		local n = 0
		for _, t in ipairs(data.toilets or {}) do
			n += Config.MERGE_COUNT ^ ((t.tier or 1) - 1)
		end
		total.Text = "Total Toilets: " .. Format.short(n)
	end

	-- This row sits directly beneath the x2 Cash badge behind a Robux glyph, so it
	-- reads as that button's price and nothing else will ever be read into it. Show
	-- the gamepass price, which is what it looked like it was showing all along.
	local robux = find("RobuxAmount") :: TextLabel?
	if robux then robux.Text = Prices.text("pass", "DoubleCash") end

	-- the small line by the cash bar: what you actually earn right now
	local multText = find("CashMultiplierText") :: TextLabel?
	if multText then multText.Text = ("x%s Cash"):format(Format.short(data.multiplier or 1)) end

	-- The green PERMANENT badge is a storefront for the x2 Cash gamepass, so it has
	-- to advertise what you would GET. Writing the player's current multiplier here
	-- made it read "1x Cash" — a button selling you nothing.
	local badge = find("MultiplierLabel") :: TextLabel?
	if badge then
		local owned = data.passes and data.passes.DoubleCash
		badge.Text = owned and ("%dx Cash ✓"):format(DOUBLE_CASH_MULT)
			or ("%dx Cash"):format(DOUBLE_CASH_MULT)
	end
end

-- ── Flush Multiplier ───────────────────────────────────────────────────
-- Its own ScreenGui, deliberately not a child of the HUD container: UIKit.pinEdges
-- re-anchors everything in there to the nearest screen edge, and this belongs in the
-- middle.
--
-- It hung in the world over the hub leaderboards until it had to be readable from a
-- farm too. No world billboard can do that -- one shrinks with distance whichever
-- unit it is sized in, and across the 200 studs from a farm to the hub it rendered
-- as a speck while still reporting 520px of layout. The reference game's own
-- multiplier is likewise invisible from its farms. On the HUD it is the same size
-- everywhere, which is what was actually asked for.
local function meterColour(mult: number): Color3
	if mult >= 2 then return Color3.fromRGB(255, 215, 60) end
	if mult >= 1.5 then return Color3.fromRGB(120, 255, 140) end
	if mult >= 1.25 then return Color3.fromRGB(150, 230, 255) end
	if mult >= 1 then return Color3.fromRGB(235, 235, 240) end
	return Color3.fromRGB(255, 120, 120)
end

function Hud.buildFlushMeter()
	local existing = gui:FindFirstChild("FlushMeterScreen")
	if existing then existing:Destroy() end

	local screen = Instance.new("ScreenGui")
	screen.Name = "FlushMeterScreen"
	screen.ResetOnSpawn = false
	screen.IgnoreGuiInset = false
	screen.DisplayOrder = 8
	screen.Parent = gui

	-- 40% of the width, top centre, clear of the Home button above it
	local panel = Instance.new("Frame")
	panel.Name = "Panel"
	panel.AnchorPoint = Vector2.new(0.5, 0)
	panel.Position = UDim2.fromScale(0.5, 0.075)
	panel.Size = UDim2.fromScale(0.4, 0.1)
	panel.BackgroundTransparency = 1
	panel.Parent = screen

	local title = Instance.new("TextLabel")
	title.Name = "Title"
	title.Size = UDim2.fromScale(1, 0.52)
	title.BackgroundTransparency = 1
	title.Font = Enum.Font.FredokaOne
	title.TextScaled = true
	title.TextColor3 = Color3.fromRGB(255, 205, 165)
	title.Text = "Flush Multiplier: 1x"
	local tls = Instance.new("UIStroke")
	tls.Thickness = 3
	tls.Color = Color3.new(0, 0, 0)
	tls.Parent = title
	title.Parent = panel

	local track = Instance.new("Frame")
	track.Name = "Track"
	track.AnchorPoint = Vector2.new(0.5, 0)
	track.Position = UDim2.fromScale(0.5, 0.56)
	track.Size = UDim2.fromScale(0.94, 0.34)
	track.BackgroundColor3 = Color3.new(1, 1, 1)
	track.BorderSizePixel = 0
	local tc = Instance.new("UICorner"); tc.CornerRadius = UDim.new(1, 0); tc.Parent = track
	local ts = Instance.new("UIStroke"); ts.Thickness = 3; ts.Color = Color3.new(0, 0, 0); ts.Parent = track
	-- The gradient is the SCALE, not a fill: it spans every multiplier the table can
	-- roll, worst on the left to best on the right, so the pointer's position alone
	-- says whether this roll was good.
	local grad = Instance.new("UIGradient")
	grad.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0.0, Color3.fromRGB(235, 90, 80)),
		ColorSequenceKeypoint.new(0.4, Color3.fromRGB(245, 165, 50)),
		ColorSequenceKeypoint.new(0.7, Color3.fromRGB(245, 225, 70)),
		ColorSequenceKeypoint.new(1.0, Color3.fromRGB(85, 220, 90)),
	})
	grad.Parent = track
	track.Parent = panel

	-- the part of the scale beyond where this roll landed, dimmed back
	local shade = Instance.new("Frame")
	shade.Name = "Shade"
	shade.AnchorPoint = Vector2.new(1, 0)
	shade.Position = UDim2.fromScale(1, 0)
	shade.Size = UDim2.fromScale(0.5, 1)
	shade.BackgroundColor3 = Color3.fromRGB(20, 20, 25)
	shade.BackgroundTransparency = 0.55
	shade.BorderSizePixel = 0
	shade.ZIndex = 2
	local sc = Instance.new("UICorner"); sc.CornerRadius = UDim.new(1, 0); sc.Parent = shade
	shade.Parent = track

	local timer = Instance.new("TextLabel")
	timer.Name = "Timer"
	timer.Size = UDim2.fromScale(1, 1)
	timer.BackgroundTransparency = 1
	timer.Font = Enum.Font.FredokaOne
	timer.TextScaled = true
	timer.TextColor3 = Color3.new(1, 1, 1)
	timer.Text = ""
	timer.ZIndex = 4
	local tp = Instance.new("UIPadding")
	tp.PaddingTop = UDim.new(0.16, 0); tp.PaddingBottom = UDim.new(0.16, 0)
	tp.Parent = timer
	local tms = Instance.new("UIStroke"); tms.Thickness = 3; tms.Color = Color3.new(0, 0, 0); tms.Parent = timer
	timer.Parent = track

	-- the marker under the bar, pointing up at where this roll landed
	local pointer = Instance.new("TextLabel")
	pointer.Name = "Pointer"
	pointer.AnchorPoint = Vector2.new(0.5, 0)
	pointer.Size = UDim2.fromScale(0.05, 0.2)
	pointer.Position = UDim2.fromScale(0.5, 0.9)
	pointer.BackgroundTransparency = 1
	pointer.Font = Enum.Font.FredokaOne
	pointer.TextScaled = true
	pointer.TextColor3 = Color3.new(0, 0, 0)
	pointer.Text = "\u{25B2}"
	pointer.ZIndex = 5
	pointer.Parent = panel

	-- where a multiplier sits along the scale: 0 at the worst roll the table can
	-- produce, 1 at the best
	local lowest, highest = math.huge, -math.huge
	for _, e in ipairs(Config.FLUSH_METER.table) do
		lowest = math.min(lowest, e.mult)
		highest = math.max(highest, e.mult)
	end

	local function show(mult: number)
		title.Text = ("Flush Multiplier: %sx"):format(mult)
		title.TextColor3 = meterColour(mult)
		local at = highest > lowest and math.clamp((mult - lowest) / (highest - lowest), 0, 1) or 0.5
		-- the pointer rides the TRACK, which is 0.94 wide and centred, not the panel
		pointer.Position = UDim2.fromScale(0.03 + at * 0.94, 0.9)
		shade.Size = UDim2.fromScale(1 - at, 1)
	end
	show(1)

	local state = { mult = 1, nextRollAt = 0 }
	Net.event(Net.NAMES.FlushMeter).OnClientEvent:Connect(function(payload)
		state = payload
		show(payload.mult)
	end)

	task.spawn(function()
		while screen.Parent do
			task.wait(0.2)
			local left = state.nextRollAt - workspace:GetServerTimeNow()
			timer.Text = left > 0 and ("Updating in %ds"):format(math.ceil(left)) or "Updating..."
		end
	end)
end

-- ── init ───────────────────────────────────────────────────────────────
function Hud.init()
	screen = gui:WaitForChild("HudScreen_PoopBasket") :: ScreenGui
	screen.Enabled = true
	screen.ResetOnSpawn = false
	screen.DisplayOrder = 10
	C = screen:WaitForChild("Container") :: Frame

	-- BEFORE bindScale: collectPacks decides which chip sells which pack from the
	-- authored top-to-bottom layout, and pinEdges is about to rewrite those positions
	collectPacks()

	-- fill: the HUD's children belong on the screen edges, not inside a centred
	-- 1920x1080 letterbox, or an ultrawide leaves them stranded mid-screen
	UIKit.bindScale(screen, true)

	Hud.buildFlushMeter()

	-- the price row is authored 71px wide and clipping, which fits two digits
	local priceRow = C:FindFirstChild("RobuxRow")
	if priceRow and priceRow:IsA("GuiObject") then
		priceRow.ClipsDescendants = false
		priceRow.AutomaticSize = Enum.AutomaticSize.X
		local amount = priceRow:FindFirstChild("RobuxAmount")
		if amount and amount:IsA("TextLabel") then
			amount.AutomaticSize = Enum.AutomaticSize.X
			amount.Size = UDim2.fromOffset(0, amount.AbsoluteSize.Y)
		end
	end

	-- side buttons
	local index = C:FindFirstChild("IndexButton")
	if index and index:IsA("GuiObject") then
		UIKit.makeInteractive(index, function()
			Audio.play("UiClick")
			Screens.toggle("IndexScreen")
		end, { onHover = function() Audio.play("UiHover", { volume = 0.4 }) end })
	end
	local rebirth = C:FindFirstChild("RebirthButton")
	if rebirth and rebirth:IsA("GuiObject") then
		UIKit.makeInteractive(rebirth, function()
			Audio.play("UiClick")
			Screens.toggle("RebirthScreen")
		end, { onHover = function() Audio.play("UiHover", { volume = 0.4 }) end })
	end
	-- Home takes you back to your own island; it used to just re-request state,
	-- and had no hover sound.
	local home = C:FindFirstChild("HomeButton")
	if home and home:IsA("GuiObject") then
		UIKit.makeInteractive(home, function()
			Audio.play("UiClick")
			Net.event(Net.NAMES.TeleportHome):FireServer()
		end, { onHover = function() Audio.play("UiHover", { volume = 0.4 }) end })
	end
	local addCash = C:FindFirstChild("AddCashButton")
	if addCash and addCash:IsA("GuiObject") then
		UIKit.makeInteractive(addCash, function()
			Audio.play("UiClick")
			Screens.openShop()
		end, { hover = 1.15 })
	end
	-- the 2x Cash badge sells the x2 Cash gamepass
	local badge = C:FindFirstChild("CashMultiplierBadge")
	if badge and badge:IsA("GuiObject") then
		UIKit.makeInteractive(badge, function()
			Audio.play("UiClick")
			MarketplaceService:PromptGamePassPurchase(player, PASS_DOUBLE_CASH)
		end, {
			hover = 1.08,
			onHover = function() Audio.play("UiHover", { volume = 0.4 }) end,
		})
	end

	State.onChanged(refresh)
	refresh(State.data, {})

end

return Hud
