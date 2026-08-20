--!strict
-- Lucky — drives the five imported Figma Lucky Block popups
-- (StarterGui.LuckyBlockPopup_<id>) and the shake-then-burst open sequence.
-- One ScreenGui per block, so the art stays exactly as designed and only the
-- data-driven bits (odds, cost, price) are written at runtime.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.ToiletConfig)
local Format = require(Shared.Format)
local Net = require(Shared.Net)
local Prices = require(Shared.Prices)

local UIKit = require(script.Parent.UIKit)
local Audio = require(script.Parent.Audio)
local State = require(script.Parent.State)
local Popups = require(script.Parent.Popups)

local player = Players.LocalPlayer
local gui = player:WaitForChild("PlayerGui")

local Lucky = {}

local ROBUX_ICON = "rbxassetid://131220159429721"
local BLOCK_IDS = { "Basic", "Green", "Ice", "Purple", "White" }

local popups: { [string]: any } = {}
local current: any = nil
local currentUid: string? = nil

-- ── gradient text ─────────────────────────────────────────────────────────
-- The import baked a UIGradient onto each outcome name. Rows are filled from
-- Config at runtime, so the gradient has to be re-coloured to match whichever
-- mutation landed in that row or it drifts out of sync with the label.
-- The tier a block rolls against. Mirrors ToiletService.currentBuyTier /
-- LuckyBlockService.baseTier, so the odds and price shown here match what the
-- server will actually roll and charge.
local function baseTier(): number
	local d = State.data
	return math.clamp(d.buyTier or 1, 1, Config.maxBuyTier(d.rebirths or 0))
end

local function totalToilets(): number
	return Config.totalToiletsOf(State.data.toilets or {})
end

local RAINBOW = ColorSequence.new({
	ColorSequenceKeypoint.new(0,   Color3.fromRGB(255, 148, 217)),
	ColorSequenceKeypoint.new(0.5, Color3.fromRGB(168, 107, 255)),
	ColorSequenceKeypoint.new(1,   Color3.fromRGB( 82, 224, 255)),
})

local function applyGradient(lbl: TextLabel, rarity: string)
	-- Luau will not accept a type-assertion as an assignment target, so narrow
	-- into a real local before touching the gradient.
	local grad = lbl:FindFirstChildOfClass("UIGradient")
	if not grad then
		grad = Instance.new("UIGradient")
		grad.Parent = lbl
	end
	grad.Rotation = 90
	if rarity == "Divine" then
		grad.Color = RAINBOW
	else
		local c = Config.RARITY_COLORS[rarity] or Color3.fromRGB(200, 200, 200)
		grad.Color = ColorSequence.new(
			c:Lerp(Color3.new(1, 1, 1), 0.45),
			c:Lerp(Color3.new(0, 0, 0), 0.20)
		)
	end
	-- a UIGradient multiplies TextColor3, so the base has to be white
	lbl.TextColor3 = Color3.new(1, 1, 1)
end

-- ── odds rows ─────────────────────────────────────────────────────────────
-- The frame has three rows; the roll table has up to eight entries. Show the
-- two most likely results plus the rarest, which is what makes the block feel
-- worth opening.
local function headline(def: any)
	local base = baseTier()
	local list = {}
	local total = 0
	for off = 0, Config.LUCKY_MAX_OFFSET do
		local w = def.roll[off]
		if w then
			total += w
			table.insert(list, { tier = Config.luckyTierFor(base, off), w = w })
		end
	end
	-- most likely first; break ties toward the higher tier so the last row is
	-- genuinely the best outcome
	table.sort(list, function(a, b)
		if a.w ~= b.w then return a.w > b.w end
		return a.tier < b.tier
	end)
	local pick = {}
	if list[1] then table.insert(pick, list[1]) end
	if list[2] then table.insert(pick, list[2]) end
	local rarest = list[#list]
	if rarest and rarest ~= list[1] and rarest ~= list[2] then table.insert(pick, rarest) end
	return pick, total
end

local function fillRows(refs: any, def: any)
	local pick, total = headline(def)
	for i = 1, 3 do
		local row = refs.rows[i]
		local e = pick[i]
		if not row then continue end
		local on = e ~= nil
		if row.name then row.name.Visible = on end
		if row.mult then row.mult.Visible = on end
		if row.pct then row.pct.Visible = on end
		if on then
			if row.name then
				row.name.Text = Config.displayName(e.tier)
				applyGradient(row.name, Config.rarityOf(e.tier))
			end
			-- the old "x5" mutation-multiplier column now carries the tier
			if row.mult then row.mult.Text = "T" .. tostring(e.tier) end
			if row.pct then row.pct.Text = ("%.4g%%"):format(e.w / total * 100) end
		end
	end
end

local function unlockCost(blockId: string): number
	return Config.luckyUnlockCost(blockId, baseTier(), totalToilets(), State.data.cash or 0)
end

-- ── binding ───────────────────────────────────────────────────────────────
local function bind(blockId: string)
	local screen = gui:WaitForChild("LuckyBlockPopup_" .. blockId, 10) :: ScreenGui?
	if not screen then
		warn("[Lucky] missing LuckyBlockPopup_" .. blockId)
		return
	end
	screen.Enabled = false
	screen.ResetOnSpawn = false
	screen.IgnoreGuiInset = true
	screen.DisplayOrder = 30
	UIKit.bindScale(screen)

	local container = screen:WaitForChild("Container") :: GuiObject
	-- park it toward the left so it does not sit on top of the player
	container.AnchorPoint = Vector2.new(0.5, 0.5)
	container.Position = UDim2.fromScale(0.24, 0.5)
	local panel = container:WaitForChild("Face") :: GuiObject

	local refs: any = {
		id = blockId,
		screen = screen,
		panel = panel,
		name = panel:FindFirstChild("BlockName", true),
		icon = panel:FindFirstChild("BlockIcon", true),
		costPill = panel:FindFirstChild("CostPill", true),
		costLabel = panel:FindFirstChild("CostLabel", true),
		buyBtn = panel:FindFirstChild("BuyButton", true),
		buyPrice = panel:FindFirstChild("BuyPrice", true),
		discardBtn = panel:FindFirstChild("DiscardButton", true),
		rows = {},
	}
	for i = 1, 3 do
		refs.rows[i] = {
			name = panel:FindFirstChild("OutcomeName" .. i, true),
			mult = panel:FindFirstChild("OutcomeMult" .. i, true),
			pct = panel:FindFirstChild("OutcomePct" .. i, true),
		}
	end

	-- the Robux glyph did not survive the Figma import, so put one back
	local buyFace = refs.buyBtn and refs.buyBtn:FindFirstChild("Face")
	if buyFace and not buyFace:FindFirstChild("RobuxIcon") then
		local ic = Instance.new("ImageLabel")
		ic.Name = "RobuxIcon"
		ic.BackgroundTransparency = 1
		ic.Image = ROBUX_ICON
		ic.ScaleType = Enum.ScaleType.Fit
		ic.Size = UDim2.fromOffset(46, 46)
		ic.Position = UDim2.fromOffset(150, 19)
		ic.ZIndex = 6
		ic.Parent = buyFace
	end

	if refs.costPill then
		UIKit.makeInteractive(refs.costPill, function()
			if not currentUid then return end
			Audio.play("UiClick")
			Net.event(Net.NAMES.OpenLucky):FireServer(currentUid, false)
		end, { onHover = function() Audio.play("UiHover", { volume = 0.4 }) end })
	end
	if refs.buyBtn then
		UIKit.makeInteractive(refs.buyBtn, function()
			if not currentUid then return end
			Audio.play("UiClick")
			Net.event(Net.NAMES.OpenLucky):FireServer(currentUid, true)
		end, { onHover = function() Audio.play("UiHover", { volume = 0.4 }) end })
	end
	if refs.discardBtn then
		UIKit.makeInteractive(refs.discardBtn, function()
			if not currentUid then return end
			Audio.play("UiClose")
			Net.event(Net.NAMES.DiscardLucky):FireServer(currentUid)
			Lucky.hide()
		end)
	end

	popups[blockId] = refs
end

-- ── api ───────────────────────────────────────────────────────────────────
function Lucky.hide(instant: boolean?)
	local refs = current
	if not refs then return end
	current = nil
	currentUid = nil
	if instant then
		refs.screen.Enabled = false
		refs.panel.Visible = true
		return
	end
	UIKit.bounceOut(refs.panel, function()
		refs.screen.Enabled = false
		refs.panel.Visible = true
	end)
end

function Lucky.show(blockId: string, uid: string)
	local refs = popups[blockId]
	if not refs then
		warn("[Lucky] no popup bound for " .. tostring(blockId))
		return
	end
	local def = Config.luckyBlock(blockId)
	if not def then return end
	if current then Lucky.hide(true) end

	current = refs
	currentUid = uid

	if refs.name then refs.name.Text = blockId end
	fillRows(refs, def)
	if refs.costLabel then
		refs.costLabel.Text = "Unlock: $" .. Format.cash(unlockCost(blockId))
	end
	-- read the live product price so the button can never advertise a number the
	-- purchase prompt would not charge
	if refs.buyPrice then
		refs.buyPrice.Text = Prices.text("product", "Lucky" .. blockId)
	end

	refs.screen.Enabled = true
	UIKit.bounceIn(refs.panel, 0.55)
	-- LuckySpawn belongs to the block appearing on the plot (see WorldFx); opening
	-- the menu is a frame opening, so it uses the normal UI open sound
	Audio.play("UiOpen")
end

-- shake the block, then burst into the reward reveal
function Lucky.playOpen(result: any)
	local refs = current
	currentUid = nil
	Audio.play("LuckyOpen")

	local function reveal()
		Popups.confettiBurst()
		task.wait(0.25)
		local tier = result.tier or 1
		local rarity = result.rarity or Config.rarityOf(tier)
		local name = result.name or Config.displayName(tier)
		Popups.discovery({
			key = Config.assetId(tier),
			name = name,
			rarity = rarity,
			weight = Config.DISCOVERY_WEIGHT[rarity] or 1,
		})
		-- offset 0 matched the tier they can already buy: the dud outcome, so it
		-- must not read like a jackpot
		if (result.offset or 0) <= 0 then
			Popups.toast(("%s (T%d) — no tier bump this time!"):format(name, tier), "info")
		else
			Popups.toast(("%s! Tier %d, +%d above your Buy Tier"):format(name, tier, result.offset), "reward")
		end
	end

	if not refs or not refs.icon then
		Lucky.hide()
		task.spawn(reveal)
		return
	end

	task.spawn(function()
		local icon = refs.icon
		local basePos = icon.Position
		local t0 = os.clock()
		local DUR = 1.1
		while os.clock() - t0 < DUR do
			local a = (os.clock() - t0) / DUR
			local amp = 14 + a * 26
			local freq = 18 + a * 30
			icon.Position = basePos + UDim2.fromOffset(math.sin((os.clock() - t0) * freq) * amp, 0)
			icon.Rotation = math.sin((os.clock() - t0) * freq) * (4 + a * 8)
			task.wait()
		end
		icon.Position = basePos
		icon.Rotation = 0
		Lucky.hide()
		reveal()
	end)
end

function Lucky.init()
	for _, id in ipairs(BLOCK_IDS) do
		bind(id)
	end
	Net.event(Net.NAMES.LuckyPrompt).OnClientEvent:Connect(function(payload)
		Lucky.show(payload.blockId, payload.uid)
	end)
	Net.event(Net.NAMES.LuckyResult).OnClientEvent:Connect(function(result)
		Lucky.playOpen(result)
	end)
end

return Lucky
