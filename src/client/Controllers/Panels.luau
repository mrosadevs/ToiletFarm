--!strict
-- Panels — Settings, Profile, Codes, Rebirth and Welcome Back.
-- The Figma frames ship with mockup values (half-filled sliders, sample stats);
-- everything here replaces those with live, interactive state.

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local MarketplaceService = game:GetService("MarketplaceService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.ToiletConfig)
local Format = require(Shared.Format)
local Net = require(Shared.Net)
local Prices = require(Shared.Prices)

-- must match PassService.PRODUCTS.DoubleOffline on the server
local PRODUCT_DOUBLE_OFFLINE = 3708663796

local UIKit = require(script.Parent.UIKit)
local Audio = require(script.Parent.Audio)
local State = require(script.Parent.State)
local Screens = require(script.Parent.Screens)
local Popups = require(script.Parent.Popups)

local player = Players.LocalPlayer
local gui = player:WaitForChild("PlayerGui")

local Panels = {}

-- ── Settings ───────────────────────────────────────────────────────────
-- Rows named SettingRow_<Key>. Music/Sfx are 0..1 drag sliders; the rest are
-- toggles that snap between empty and full.
local SETTING_KIND = {
	Music = "slider", Sfx = "slider",
	MuteToilets = "toggle", AutoPoop = "toggle", AutoCash = "toggle",
}

local TOGGLE_ON  = Color3.fromRGB(30, 255, 0)
local TOGGLE_OFF = Color3.fromRGB(26, 26, 26)

-- Music/Sfx are drag sliders (SliderTrack); the rest are switches (SettingToggle)
-- whose knob slides between the two ends. Both ship half-filled as Figma mockups.
local function setSliderVisual(row: Frame, value: number)
	local track = row:FindFirstChild("SliderTrack") :: Frame?
	if track then
		local fill = track:FindFirstChild("SliderFill") :: Frame?
		local knob = track:FindFirstChild("SliderKnob") :: Frame?
		value = math.clamp(value, 0, 1)
		if fill then fill.Size = UDim2.new(value, 0, 1, 0) end
		if knob then
			knob.Position = UDim2.new(value, -knob.Size.X.Offset / 2, knob.Position.Y.Scale, knob.Position.Y.Offset)
		end
		return
	end

	local toggle = row:FindFirstChild("SettingToggle") :: Frame?
	if not toggle then return end
	local on = value >= 0.5
	local knob = toggle:FindFirstChild("ToggleKnob") :: Frame?
	TweenService:Create(toggle, TweenInfo.new(0.16), {
		BackgroundColor3 = on and TOGGLE_ON or TOGGLE_OFF,
	}):Play()
	if knob then
		local travel = toggle.Size.X.Offset - knob.Size.X.Offset - 8
		TweenService:Create(knob, TweenInfo.new(0.18, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
			Position = UDim2.new(0, on and (4 + travel) or 4, knob.Position.Y.Scale, knob.Position.Y.Offset),
		}):Play()
	end
end

local function bindSettingRow(row: Frame, key: string)
	local kind = SETTING_KIND[key]
	if not kind then return end

	local function commit(v: any)
		Net.event(Net.NAMES.SetSetting):FireServer(key, v)
	end

	if kind == "toggle" then
		local toggle = row:FindFirstChild("SettingToggle") :: Frame?
		if not toggle then return end
		-- the whole row is the hit target, which is far easier to click than the switch
		UIKit.makeInteractive(row, function()
			Audio.play("UiClick")
			local current = State.data.settings[key] == true
			State.data.settings[key] = not current
			setSliderVisual(row, current and 0 or 1)
			commit(not current)
		end, { hover = 1.02, press = 0.98 })
	else
		local track = row:FindFirstChild("SliderTrack") :: Frame?
		if not track then return end
		local hit = UIKit.hitbox(track)
		local dragging = false
		local function valueFromX(x: number): number
			local left = track.AbsolutePosition.X
			local w = track.AbsoluteSize.X
			if w <= 0 then return 0 end
			return math.clamp((x - left) / w, 0, 1)
		end
		hit.MouseButton1Down:Connect(function()
			dragging = true
			Audio.play("UiClick", { volume = 0.5 })
		end)
		UserInputService.InputEnded:Connect(function(input)
			if dragging and (input.UserInputType == Enum.UserInputType.MouseButton1
				or input.UserInputType == Enum.UserInputType.Touch) then
				dragging = false
				commit(valueFromX(input.Position.X))
			end
		end)
		RunService.RenderStepped:Connect(function()
			if not dragging then return end
			local pos = UserInputService:GetMouseLocation()
			local v = valueFromX(pos.X)
			setSliderVisual(row, v)
			State.data.settings[key] = v
			Audio.applySettings(State.data.settings)
		end)
	end
end

local function refreshSettings()
	local screen = gui:FindFirstChild("SettingsScreen")
	if not screen then return end
	local panel = screen:FindFirstChild("SettingsPanel", true)
	if not panel then return end
	for _, row in ipairs(panel:GetChildren()) do
		local key = row.Name:match("^SettingRow_(.+)$")
		if key and row:IsA("Frame") then
			local v = State.data.settings[key]
			if type(v) == "boolean" then
				setSliderVisual(row, v and 1 or 0)
			elseif type(v) == "number" then
				setSliderVisual(row, v)
			end
		end
	end
end

local function initSettings()
	local screen = Screens.register("SettingsScreen", refreshSettings)
	if not screen then return end
	local panel = screen:FindFirstChild("SettingsPanel", true)
	if not panel then return end
	for _, row in ipairs(panel:GetChildren()) do
		local key = row.Name:match("^SettingRow_(.+)$")
		if key and row:IsA("Frame") then bindSettingRow(row, key) end
	end
end

-- ── Profile ────────────────────────────────────────────────────────────
local function refreshProfile()
	local screen = gui:FindFirstChild("ProfileScreen")
	if not screen then return end
	local panel = screen:FindFirstChild("ProfilePanel", true)
	if not panel then return end
	local d = State.data
	local rows = {
		Networth = "$" .. Format.cash(d.cash),
		Toilets  = ("%d / %d slots"):format(#(d.toilets or {}), d.slots or 8),
		Time     = Format.duration((d.stats and d.stats.playtime) or 0),
	}
	for _, row in ipairs(panel:GetChildren()) do
		local key = row.Name:match("^StatRow_(.+)$")
		if key and rows[key] then
			local value = row:FindFirstChild("StatValue") :: TextLabel?
			if value then value.Text = rows[key] end
		end
	end
end

-- ── Codes ──────────────────────────────────────────────────────────────
local function initCodes()
	local screen = Screens.register("RedeemCodesScreen")
	if not screen then return end
	local panel = screen:FindFirstChild("RedeemCodesPanel", true)
	if not panel then return end
	local inputFrame = panel:FindFirstChild("CodeInput") :: Frame?
	local redeem = panel:FindFirstChild("RedeemButton") :: Frame?
	if not inputFrame then return end

	-- the mockup has a static placeholder label; give it a real TextBox
	local placeholder = inputFrame:FindFirstChild("CodePlaceholder") :: TextLabel?
	local box = inputFrame:FindFirstChild("CodeBox") :: TextBox?
	if not box then
		box = Instance.new("TextBox")
		box.Name = "CodeBox"
		box.Size = UDim2.fromScale(1, 1)
		box.BackgroundTransparency = 1
		box.Font = placeholder and placeholder.Font or Enum.Font.FredokaOne
		box.TextScaled = true
		box.TextColor3 = Color3.new(1, 1, 1)
		box.PlaceholderText = "Enter code here..."
		box.PlaceholderColor3 = Color3.fromRGB(150, 150, 160)
		box.Text = ""
		box.ClearTextOnFocus = false
		box.ZIndex = 20
		local pad = Instance.new("UIPadding")
		pad.PaddingLeft = UDim.new(0, 18); pad.PaddingRight = UDim.new(0, 18)
		pad.PaddingTop = UDim.new(0, 12); pad.PaddingBottom = UDim.new(0, 12)
		pad.Parent = box
		box.Parent = inputFrame
	end
	if placeholder then placeholder.Visible = false end

	local function submit()
		local code = box.Text
		if code == "" then
			Popups.toast("Type a code first!", "error")
			return
		end
		Audio.play("UiClick")
		Net.event(Net.NAMES.RedeemCode):FireServer(code)
		box.Text = ""
	end

	box.FocusLost:Connect(function(enter) if enter then submit() end end)
	if redeem then
		UIKit.makeInteractive(redeem, submit, {
			onHover = function() Audio.play("UiHover", { volume = 0.4 }) end,
		})
	end
end

-- ── Rebirth ────────────────────────────────────────────────────────────
local function refreshRebirth()
	local screen = gui:FindFirstChild("RebirthScreen")
	if not screen then return end
	local panel = screen:FindFirstChild("RebirthPanel", true)
	if not panel then return end
	local d = State.data
	local nextLevel = (d.rebirths or 0) + 1
	local cost = Config.rebirthCost(d.rebirths or 0)
	local entry = Config.REBIRTHS[nextLevel]

	local box = panel:FindFirstChild("RequirementBox") :: Frame?
	if box then
		local value = box:FindFirstChild("RequirementValue") :: TextLabel?
		if value then
			value.Text = cost
				and ("$%s / %s"):format(Format.short(d.cash), Format.short(cost))
				or "MAX REBIRTH"
		end
		local track = box:FindFirstChild("ProgressTrack") :: Frame?
		if track then
			local fill = track:FindFirstChild("ProgressFill") :: Frame?
			if not fill then
				fill = Instance.new("Frame")
				fill.Name = "ProgressFill"
				fill.BackgroundColor3 = Color3.fromRGB(60, 230, 90)
				fill.BorderSizePixel = 0
				fill.Size = UDim2.fromScale(0, 1)
				fill.ZIndex = (track.ZIndex or 1) + 1
				local c = Instance.new("UICorner")
				c.CornerRadius = UDim.new(1, 0)
				c.Parent = fill
				fill.Parent = track
			end
			local pct = cost and math.clamp(d.cash / cost, 0, 1) or 1
			TweenService:Create(fill, TweenInfo.new(0.3), { Size = UDim2.fromScale(pct, 1) }):Play()
		end
	end

	-- "You will receive" cards
	local tiers = panel:FindFirstChild("RewardTiers")
	local cashCard = panel:FindFirstChild("RewardCash")
	local function setCard(card: Instance?, text: string)
		if not card then return end
		-- The Figma import already ships a RewardLabel on each card. Creating a second
		-- label stacked both on top of each other ("Buy up to T9" over "+2 New Buy Tiers").
		local label = card:FindFirstChild("RewardLabel", true) :: TextLabel?
			or card:FindFirstChild("RewardValue", true) :: TextLabel?
		if not label then
			label = Instance.new("TextLabel")
			label.Name = "RewardValue"
			label.Size = UDim2.fromScale(1, 0.34)
			label.Position = UDim2.fromScale(0, 0.62)
			label.BackgroundTransparency = 1
			label.Font = Enum.Font.FredokaOne
			label.TextScaled = true
			label.TextColor3 = Color3.new(1, 1, 1)
			label.ZIndex = 30
			local s = Instance.new("UIStroke")
			s.Thickness = 3; s.Color = Color3.new(0, 0, 0); s.Parent = label
			label.Parent = card
		end
		label.Text = text
	end
	setCard(tiers, entry and ("Buy up to T%d"):format(Config.maxBuyableTier(nextLevel)) or "MAX")
	setCard(cashCard, entry and ("x%s income"):format(entry.mult) or "MAX")

	local btn = panel:FindFirstChild("RebirthButton") :: Frame?
	if btn then
		local face = btn:FindFirstChild("Face") :: Frame?
		if face then
			-- matches the world pads: green you can buy it, red you cannot pay for it,
			-- grey there is nothing left to buy
			if cost == nil then
				face.BackgroundColor3 = Color3.fromRGB(110, 110, 118)
			elseif d.cash >= cost then
				face.BackgroundColor3 = Color3.fromRGB(60, 230, 60)
			else
				face.BackgroundColor3 = Color3.fromRGB(178, 52, 52)
			end
		end
	end
end

local function initRebirth()
	local screen = Screens.register("RebirthScreen", refreshRebirth)
	if not screen then return end
	local panel = screen:FindFirstChild("RebirthPanel", true)
	if not panel then return end

	local btn = panel:FindFirstChild("RebirthButton") :: Frame?
	if btn then
		UIKit.makeInteractive(btn, function()
			local cost = Config.rebirthCost(State.data.rebirths or 0)
			if not cost or State.data.cash < cost then
				Popups.toast("Not enough cash to rebirth!", "error")
				return
			end
			Audio.play("Rebirth")
			Net.event(Net.NAMES.Rebirth):FireServer()
			Screens.close("RebirthScreen")
		end, { onHover = function() Audio.play("UiHover", { volume = 0.4 }) end })
	end
	local skip = panel:FindFirstChild("SkipButton") :: Frame?
	if skip then
		UIKit.makeInteractive(skip, function()
			Audio.play("UiClick")
			Popups.toast("Instant Rebirth coming soon!", "info")
		end)
	end
end

-- ── Welcome Back ───────────────────────────────────────────────────────
local function initWelcomeBack()
	local screen = Screens.register("WelcomeBackScreen")
	if not screen then return end
	local panel = screen:FindFirstChild("Panel", true)
	if not panel then return end

	local claim = panel:FindFirstChild("ClaimButton") :: Frame?
	local double = panel:FindFirstChild("DoublePoopsButton") :: Frame?
	if claim then
		UIKit.makeInteractive(claim, function()
			Audio.play("UiClick")
			Net.event(Net.NAMES.ClaimOffline):FireServer(false)
			Screens.close("WelcomeBackScreen")
		end, { onHover = function() Audio.play("UiHover", { volume = 0.4 }) end })
	end
	if double then
		-- the x2 claim is granted by the dev product receipt, never by the client
		UIKit.makeInteractive(double, function()
			Audio.play("UiClick")
			local id = PRODUCT_DOUBLE_OFFLINE
			if id == 0 then
				Popups.toast("x2 Poops product coming soon!", "info")
				return
			end
			MarketplaceService:PromptProductPurchase(player, id)
		end, { onHover = function() Audio.play("UiHover", { volume = 0.4 }) end })

		-- Show the real buyer price. The authored label is called RobuxAmount, not
		-- Price, so this only ever looked at a name that does not exist and the mockup
		-- number baked into the button (72) survived into the live game.
		local tag = panel:FindFirstChild("DoubleTag", true) :: TextLabel?
		local priceLabel = double:FindFirstChild("RobuxAmount", true) :: TextLabel?
			or double:FindFirstChild("Price", true) :: TextLabel?
		local shown = Prices.product("DoubleOffline")
		if priceLabel and shown then priceLabel.Text = tostring(shown) end
		if tag then tag.Text = "x2 Poops!" end
	end

	Net.event(Net.NAMES.OfflineReport).OnClientEvent:Connect(function(payload)
		local amount = panel:FindFirstChild("Amount") :: TextLabel?
		if amount then amount.Text = ("%s Poops"):format(Format.comma(payload.poops)) end
		-- footer line: how long they were away
		local footer = panel:FindFirstChild("AwayFooter") :: TextLabel?
		if not footer then
			footer = Instance.new("TextLabel")
			footer.Name = "AwayFooter"
			footer.Size = UDim2.new(1, 0, 0, 34)
			footer.Position = UDim2.new(0, 0, 1, -44)
			footer.BackgroundTransparency = 1
			footer.Font = Enum.Font.FredokaOne
			footer.TextSize = 26
			footer.TextColor3 = Color3.fromRGB(200, 200, 210)
			local s = Instance.new("UIStroke")
			s.Thickness = 2.5; s.Color = Color3.new(0, 0, 0); s.Parent = footer
			footer.Parent = panel
		end
		footer.Text = ("You were away for %s"):format(Format.duration(payload.seconds))
		-- remember what the x2 button would be worth, purely for the label
		local doubleTag = panel:FindFirstChild("DoubleTag", true) :: TextLabel?
		if doubleTag then
			doubleTag.Text = ("x2 = %s Poops!"):format(Format.short(payload.poops * 2))
		end
		Screens.open("WelcomeBackScreen")
	end)
end

-- ── init ───────────────────────────────────────────────────────────────
function Panels.init()
	initSettings()
	Screens.register("ProfileScreen", refreshProfile)
	initCodes()
	initRebirth()
	initWelcomeBack()

	-- the first state push can land before these listeners exist
	refreshSettings()
	refreshProfile()
	refreshRebirth()
	Audio.applySettings(State.data.settings)

	State.onChanged(function(_, changed)
		if changed.settings then
			Audio.applySettings(State.data.settings)
			refreshSettings()
		end
		if Screens.isOpen("ProfileScreen") then refreshProfile() end
		if Screens.isOpen("RebirthScreen") then refreshRebirth() end
	end)
end

return Panels
