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
	-- top to bottom = small, medium, large
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

-- ── Flush Meter readout ─────────────────────────────────────────────────
-- The multiplier is SERVER-WIDE (see FlushMeterService), so it is banner furniture,
-- not a personal stat: headline across the top middle of the screen with a countdown
-- bar under it, where every player in the server is looking at the same number.
local meterFrame: Frame
local meterValue: TextLabel
local meterTimer: TextLabel
local meterFill: Frame
local meterState = { mult = 1, nextRollAt = 0, period = 30 }

local function buildFlushMeter()
	local f = Instance.new("Frame")
	f.Name = "FlushMeter"
	f.AnchorPoint = Vector2.new(0.5, 0)
	f.Position = UDim2.new(0.5, 0, 0, 104)
	f.Size = UDim2.fromOffset(620, 104)
	f.BackgroundTransparency = 1
	f.BorderSizePixel = 0

	-- one bold line, no box behind it: the world reads through it like the reference
	meterValue = Instance.new("TextLabel")
	meterValue.Name = "MeterHeadline"
	meterValue.Size = UDim2.new(1, 0, 0, 54)
	meterValue.BackgroundTransparency = 1
	meterValue.Font = Enum.Font.FredokaOne
	meterValue.TextScaled = true
	meterValue.TextColor3 = Color3.fromRGB(255, 235, 140)
	meterValue.Text = "Flush Multiplier: 1x"
	local vs = Instance.new("UIStroke")
	vs.Thickness = 4; vs.Color = Color3.new(0, 0, 0); vs.Parent = meterValue
	meterValue.Parent = f

	local track = Instance.new("Frame")
	track.Name = "MeterTrack"
	track.AnchorPoint = Vector2.new(0.5, 0)
	track.Position = UDim2.new(0.5, 0, 0, 60)
	track.Size = UDim2.fromOffset(470, 40)
	track.BackgroundColor3 = Color3.fromRGB(28, 28, 32)
	track.BorderSizePixel = 0
	local tc = Instance.new("UICorner"); tc.CornerRadius = UDim.new(1, 0); tc.Parent = track
	local tstroke = Instance.new("UIStroke")
	tstroke.Thickness = 3; tstroke.Color = Color3.new(0, 0, 0); tstroke.Parent = track
	track.Parent = f

	meterFill = Instance.new("Frame")
	meterFill.Name = "MeterFill"
	meterFill.Size = UDim2.fromScale(0, 1)
	meterFill.BackgroundColor3 = Color3.new(1, 1, 1)
	meterFill.BorderSizePixel = 0
	local fc = Instance.new("UICorner"); fc.CornerRadius = UDim.new(1, 0); fc.Parent = meterFill
	local grad = Instance.new("UIGradient")
	grad.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0.0, Color3.fromRGB(235, 70, 60)),
		ColorSequenceKeypoint.new(0.4, Color3.fromRGB(245, 165, 50)),
		ColorSequenceKeypoint.new(0.7, Color3.fromRGB(245, 225, 70)),
		ColorSequenceKeypoint.new(1.0, Color3.fromRGB(85, 220, 90)),
	})
	grad.Parent = meterFill
	meterFill.Parent = track

	meterTimer = Instance.new("TextLabel")
	meterTimer.Name = "MeterTimer"
	meterTimer.Size = UDim2.fromScale(1, 1)
	meterTimer.BackgroundTransparency = 1
	meterTimer.Font = Enum.Font.FredokaOne
	meterTimer.TextScaled = true
	meterTimer.TextColor3 = Color3.new(1, 1, 1)
	meterTimer.Text = ""
	meterTimer.ZIndex = 3
	local tp = Instance.new("UIPadding")
	tp.PaddingTop = UDim.new(0, 7); tp.PaddingBottom = UDim.new(0, 7)
	tp.Parent = meterTimer
	local ms = Instance.new("UIStroke")
	ms.Thickness = 3; ms.Color = Color3.new(0, 0, 0); ms.Parent = meterTimer
	meterTimer.Parent = track

	f.Parent = C
	meterFrame = f
end

local function meterColor(mult: number): Color3
	if mult >= 2 then return Color3.fromRGB(255, 215, 60) end
	if mult >= 1.5 then return Color3.fromRGB(120, 255, 140) end
	if mult >= 1.25 then return Color3.fromRGB(150, 230, 255) end
	if mult >= 1 then return Color3.fromRGB(235, 235, 240) end
	return Color3.fromRGB(255, 120, 120)
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

	local poops = find("PoopsAmount") :: TextLabel?
	if poops then
		poops.Text = Format.short(data.poops)
		if changed.poops then UIKit.pop(poops, 1.12) end
	end

	-- basket header doubles as the carry gauge
	local poopsTitle = find("PoopsTitle") :: TextLabel?
	if poopsTitle then
		local full = (data.poopItems or 0) >= (data.carryCap or 25)
		poopsTitle.Text = full and "FULL!" or "Poops"
		poopsTitle.TextColor3 = full and Color3.fromRGB(255, 120, 120) or Color3.new(1, 1, 1)
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

	local robux = find("RobuxAmount") :: TextLabel?
	if robux then robux.Text = tostring(data.tokens or 0) end

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

-- ── init ───────────────────────────────────────────────────────────────
function Hud.init()
	screen = gui:WaitForChild("HudScreen_PoopBasket") :: ScreenGui
	screen.Enabled = true
	screen.ResetOnSpawn = false
	screen.DisplayOrder = 10
	-- fill: the HUD's children belong on the screen edges, not inside a centred
	-- 1920x1080 letterbox, or an ultrawide leaves them stranded mid-screen
	UIKit.bindScale(screen, true)
	C = screen:WaitForChild("Container") :: Frame

	collectPacks()
	buildFlushMeter()

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

	-- Flush Meter feed
	Net.event(Net.NAMES.FlushMeter).OnClientEvent:Connect(function(payload)
		meterState = payload
		meterValue.Text = ("Flush Multiplier: %sx"):format(payload.mult)
		meterValue.TextColor3 = meterColor(payload.mult)
		UIKit.pop(meterFrame, 1.12)
	end)

	-- countdown to the next roll, so players can sprint to bank a good one
	task.spawn(function()
		while true do
			task.wait(0.1)
			if meterTimer and meterState.nextRollAt then
				local period = meterState.period or Config.FLUSH_METER.period
				local left = meterState.nextRollAt - workspace:GetServerTimeNow()
				if left > 0 then
					meterTimer.Text = ("Updating in %ds"):format(math.ceil(left))
					-- the bar fills toward the re-roll rather than draining, so a full
					-- bar reads as "about to change" at a glance
					meterFill.Size = UDim2.fromScale(math.clamp((period - left) / period, 0, 1), 1)
				else
					meterTimer.Text = "Updating..."
					meterFill.Size = UDim2.fromScale(1, 1)
				end
			end
		end
	end)
end

return Hud
