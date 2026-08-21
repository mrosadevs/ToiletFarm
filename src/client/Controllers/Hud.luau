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
local meterFrame: Frame
local meterValue: TextLabel
local meterTimer: TextLabel
local meterState = { mult = 1, nextRollAt = 0 }

local function buildFlushMeter()
	local f = Instance.new("Frame")
	f.Name = "FlushMeter"
	-- top-centre, directly under the Home button: it is the thing you sprint to bank
	-- a good roll against, so it belongs where the eye already is, not in a corner
	f.AnchorPoint = Vector2.new(0.5, 0)
	f.Position = UDim2.new(0.5, 0, 0, 110)
	f.Size = UDim2.fromOffset(300, 96)
	f.BackgroundColor3 = Color3.fromRGB(24, 24, 28)
	f.BackgroundTransparency = 0.15
	f.BorderSizePixel = 0
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 14)
	corner.Parent = f
	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 3
	stroke.Color = Color3.new(0, 0, 0)
	stroke.Parent = f

	local title = Instance.new("TextLabel")
	title.Size = UDim2.new(1, 0, 0, 26)
	title.Position = UDim2.fromOffset(0, 6)
	title.BackgroundTransparency = 1
	title.Font = Enum.Font.FredokaOne
	title.TextSize = 22
	title.TextColor3 = Color3.fromRGB(230, 230, 235)
	title.Text = "FLUSH METER"
	local ts = Instance.new("UIStroke"); ts.Thickness = 2; ts.Color = Color3.new(0,0,0); ts.Parent = title
	title.Parent = f

	meterValue = Instance.new("TextLabel")
	meterValue.Size = UDim2.new(1, 0, 0, 42)
	meterValue.Position = UDim2.fromOffset(0, 28)
	meterValue.BackgroundTransparency = 1
	meterValue.Font = Enum.Font.FredokaOne
	meterValue.TextSize = 40
	meterValue.Text = "x1"
	local vs = Instance.new("UIStroke"); vs.Thickness = 3; vs.Color = Color3.new(0,0,0); vs.Parent = meterValue
	meterValue.Parent = f

	meterTimer = Instance.new("TextLabel")
	meterTimer.Size = UDim2.new(1, 0, 0, 22)
	meterTimer.Position = UDim2.fromOffset(0, 70)
	meterTimer.BackgroundTransparency = 1
	meterTimer.Font = Enum.Font.FredokaOne
	meterTimer.TextSize = 18
	meterTimer.TextColor3 = Color3.fromRGB(200, 200, 210)
	meterTimer.Text = ""
	local ms = Instance.new("UIStroke"); ms.Thickness = 2; ms.Color = Color3.new(0,0,0); ms.Parent = meterTimer
	meterTimer.Parent = f

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

	local multText = find("CashMultiplierText") :: TextLabel?
	if multText then multText.Text = ("x%s Cash"):format(Format.short(data.multiplier or 1)) end

	local badge = find("MultiplierLabel") :: TextLabel?
	if badge then badge.Text = ("%sx Cash"):format(Format.short(data.multiplier or 1)) end
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
		meterValue.Text = ("x%s"):format(payload.mult)
		meterValue.TextColor3 = meterColor(payload.mult)
		UIKit.pop(meterFrame, 1.12)
	end)

	-- countdown to the next roll, so players can sprint to bank a good one
	task.spawn(function()
		while true do
			task.wait(0.1)
			if meterTimer and meterState.nextRollAt then
				local left = meterState.nextRollAt - workspace:GetServerTimeNow()
				if left <= Config.FLUSH_METER.warn and left > 0 then
					meterTimer.Text = ("re-rolls in %.1fs"):format(left)
					meterTimer.TextColor3 = Color3.fromRGB(255, 190, 90)
				elseif left > 0 then
					meterTimer.Text = ("%ds"):format(math.ceil(left))
					meterTimer.TextColor3 = Color3.fromRGB(190, 190, 200)
				else
					meterTimer.Text = ""
				end
			end
		end
	end)
end

return Hud
