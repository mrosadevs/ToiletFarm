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
local UserInputService = game:GetService("UserInputService")
local GuiService = game:GetService("GuiService")

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
-- clear space between the balance pill, the + button and the line beside it
local CASH_ROW_GAP = 12

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

-- ── mobile: keep Home clear of the Roblox topbar ─────────────────────────
-- HudScreen_PoopBasket sets IgnoreGuiInset, so the container's top edge is the
-- true top of the screen and HomeButton is authored flush against it at y = 0.
-- On desktop Roblox's own controls are narrow enough that Home clears them. On a
-- phone the topbar is taller and its buttons run further across, so they sit
-- directly on top of Home and swallow the tap.
--
-- Touch-only, so the authored desktop layout is left exactly as it is -- a device
-- with both touch and a keyboard is a laptop or a Windows tablet and gets the
-- desktop topbar.
local TOPBAR_MARGIN = 12 -- design px of breathing room under the inset

local function keepHomeClearOfTopbar(home: GuiObject)
	if not (UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled) then return end
	local container = home.Parent
	if not container or not container:IsA("GuiObject") then return end
	local authoredY = home.Position.Y.Offset

	local function apply()
		-- GetGuiInset is in real screen pixels, but everything inside the container
		-- is in unscaled design pixels behind FigBloxUIViewportScale. Convert, or the
		-- drop is wrong by whatever the viewport scale happens to be.
		local scale = container:FindFirstChild("FigBloxUIViewportScale") :: UIScale?
		local k = (scale and scale.Scale > 0) and scale.Scale or 1
		local inset = GuiService:GetGuiInset().Y / k
		home.Position = UDim2.new(
			home.Position.X.Scale,
			home.Position.X.Offset,
			home.Position.Y.Scale,
			authoredY + inset + TOPBAR_MARGIN
		)
	end

	apply()
	-- rotation and resize change both the inset and the viewport scale
	container:GetPropertyChangedSignal("AbsoluteSize"):Connect(apply)
end

local function collectPacks()
	packs = {}
	for _, c in ipairs(C:GetChildren()) do
		if c:IsA("Frame") and c.Name == "CashGainChip" then table.insert(packs, c) end
	end
	-- Top to bottom = small, medium, large. This reads the AUTHORED offsets, so it
	-- has to run before UIKit.pinEdges re-anchors these to the bottom edge and the
	-- offsets stop being a screen ordering.
	table.sort(packs, function(a, b)
		return a.Position.Y.Offset < b.Position.Y.Offset
	end)

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
			onHover = function()
				Audio.play("UiHover", { volume = 0.4 })
			end,
		})
	end
end

local function refreshPacks(cash: number)
	for index, chip in ipairs(packs) do
		local label = chip:FindFirstChild("GainLabel", true) :: TextLabel?
		if label then label.Text = "+" .. Format.cash(Config.cashPackAmount(cash, index)) .. "$" end
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
			UIKit.rollNumber(cashLabel, lastCash, data.cash, function(v)
				return "$" .. Format.cash(v)
			end)
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

	-- The line beside the + button advertises what that button hands over -- the
	-- smallest cash pack, scaled to the balance like the chips down the left edge.
	-- It used to show the income multiplier, which read as a label for the + button
	-- and described something else entirely.
	local multText = find("CashMultiplierText") :: TextLabel?
	if multText then multText.Text = "+" .. Format.cash(Config.cashPackAmount(data.cash, 1)) .. "$" end

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
	C = screen:WaitForChild("Container") :: Frame

	-- BEFORE bindScale: collectPacks decides which chip sells which pack from the
	-- authored top-to-bottom layout, and pinEdges is about to rewrite those positions
	collectPacks()

	-- fill: the HUD's children belong on the screen edges, not inside a centred
	-- 1920x1080 letterbox, or an ultrawide leaves them stranded mid-screen
	UIKit.bindScale(screen, true)

	-- The Flush Multiplier is NOT on this screen. It is one server-wide number, so it
	-- hangs over the hub leaderboards where everyone reads the same figure -- see
	-- WorldFx.buildFlushHologram.

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
		end, {
			onHover = function()
				Audio.play("UiHover", { volume = 0.4 })
			end,
		})
	end
	local rebirth = C:FindFirstChild("RebirthButton")
	if rebirth and rebirth:IsA("GuiObject") then
		UIKit.makeInteractive(rebirth, function()
			Audio.play("UiClick")
			Screens.toggle("RebirthScreen")
		end, {
			onHover = function()
				Audio.play("UiHover", { volume = 0.4 })
			end,
		})
	end
	-- Home takes you back to your own island; it used to just re-request state,
	-- and had no hover sound.
	local home = C:FindFirstChild("HomeButton")
	if home and home:IsA("GuiObject") then
		keepHomeClearOfTopbar(home)
		UIKit.makeInteractive(home, function()
			Audio.play("UiClick")
			Net.event(Net.NAMES.TeleportHome):FireServer()
		end, {
			onHover = function()
				Audio.play("UiHover", { volume = 0.4 })
			end,
		})
	end
	-- The + by the balance is a buy-cash button, so it goes straight to the smallest
	-- pack rather than opening a shop to pick from.
	local addCash = C:FindFirstChild("AddCashButton")
	if addCash and addCash:IsA("GuiObject") then
		UIKit.makeInteractive(addCash, function()
			Audio.play("UiClick")
			local id = PRODUCT_IDS[1]
			if not id or id == 0 then
				require(script.Parent.Popups).toast("Coming soon!", "error")
				return
			end
			MarketplaceService:PromptProductPurchase(player, id)
		end, { hover = 1.15 })
	end

	-- The + button is authored overlapping the balance pill (the bar ends at 277,
	-- the button starts at 265) and the line beside it sits tight against both.
	-- Slide the pair right so the row reads as three separate things.
	local bar = C:FindFirstChild("CashBar")
	local multLine = C:FindFirstChild("CashMultiplierText")
	if bar and bar:IsA("GuiObject") and addCash and addCash:IsA("GuiObject") then
		local barRight = bar.Position.X.Offset + bar.Size.X.Offset
		local delta = (barRight + CASH_ROW_GAP) - addCash.Position.X.Offset
		if delta > 0 then
			addCash.Position += UDim2.fromOffset(delta, 0)
			if multLine and multLine:IsA("GuiObject") then
				multLine.Position += UDim2.fromOffset(delta, 0)
			end
		end
	end
	-- the 2x Cash badge sells the x2 Cash gamepass
	local badge = C:FindFirstChild("CashMultiplierBadge")
	if badge and badge:IsA("GuiObject") then
		UIKit.makeInteractive(badge, function()
			Audio.play("UiClick")
			MarketplaceService:PromptGamePassPurchase(player, PASS_DOUBLE_CASH)
		end, {
			hover = 1.08,
			onHover = function()
				Audio.play("UiHover", { volume = 0.4 })
			end,
		})
	end

	State.onChanged(refresh)
	refresh(State.data, {})
end

return Hud
