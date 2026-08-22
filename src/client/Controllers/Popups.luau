--!strict
-- Popups — the floating feedback layer: +N poop chips over the basket, the
-- discovery callout, deposit confetti rain, and toasts.

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.ToiletConfig)
local Format = require(Shared.Format)
local IconManifest = require(Shared.IconManifest)

local UIKit = require(script.Parent.UIKit)
local Audio = require(script.Parent.Audio)

local player = Players.LocalPlayer
local gui = player:WaitForChild("PlayerGui")

local Popups = {}

local layer: ScreenGui

function Popups.init()
	layer = Instance.new("ScreenGui")
	layer.Name = "PopupLayer"
	layer.ResetOnSpawn = false
	layer.IgnoreGuiInset = true
	layer.DisplayOrder = 40
	layer.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	layer.Parent = gui
end

local function outlined(text: string, size: number, color: Color3): TextLabel
	local l = Instance.new("TextLabel")
	l.BackgroundTransparency = 1
	l.Font = Enum.Font.FredokaOne
	l.Text = text
	l.TextSize = size
	l.TextColor3 = color
	local stroke = Instance.new("UIStroke")
	stroke.Thickness = math.max(2, size / 12)
	stroke.Color = Color3.new(0, 0, 0)
	stroke.Parent = l
	return l
end
Popups.outlined = outlined

-- ── +N poop chips ────────────────────────────────────────────────────────
-- These land right above the basket at the bottom of the screen, the way the
-- reference game stacks its +1 / +25 / +90 chips.
local BASKET_ANCHOR = UDim2.fromScale(0.5, 0.80)

-- One gradient per tier, cycled, so a heap of mixed droppings comes up in mixed
-- colours instead of a column of identical white numbers. Keyed to the tier rather
-- than random, so the same toilet always reads the same way.
-- Saturated top to bottom. These started at near-white and read as pastel once the
-- black stroke was around them; a gradient on text wants real colour at both ends.
local GAIN_GRADIENTS = {
	ColorSequence.new(Color3.fromRGB(255, 225,  60), Color3.fromRGB(240, 120,   0)),
	ColorSequence.new(Color3.fromRGB(120, 255, 120), Color3.fromRGB(  0, 175,  55)),
	ColorSequence.new(Color3.fromRGB(110, 225, 255), Color3.fromRGB(  0, 120, 245)),
	ColorSequence.new(Color3.fromRGB(255, 130, 210), Color3.fromRGB(215,   0, 140)),
	ColorSequence.new(Color3.fromRGB(200, 150, 255), Color3.fromRGB(115,  30, 235)),
	ColorSequence.new(Color3.fromRGB(255, 165, 100), Color3.fromRGB(230,  70,  10)),
}

function Popups.poopGain(amount: number, big: boolean?, tier: number?)
	if not layer then return end
	local size = big and 66 or 48
	local l = outlined("+" .. Format.short(amount), size, Color3.new(1, 1, 1))
	-- Rainbow is reserved for a genuinely rare dropping. Keying it off cash value
	-- meant every pickup on a grown farm cleared the threshold and came up rainbow,
	-- which is exactly the sameness the per-tier colours are here to break.
	if big then
		UIKit.gradient(l, UIKit.RAINBOW, 0)
	else
		UIKit.gradient(l, GAIN_GRADIENTS[((tier or 1) - 1) % #GAIN_GRADIENTS + 1], 90)
	end
	l.Size = UDim2.fromOffset(300, size + 14)
	l.AnchorPoint = Vector2.new(0.5, 0.5)
	local jitterX = (math.random() - 0.5) * 0.16
	l.Position = BASKET_ANCHOR + UDim2.fromScale(jitterX, 0)
	l.ZIndex = 5
	l.Parent = layer
	UIKit.pop(l, 1.5)

	local rise = 0.10 + math.random() * 0.05
	local t = TweenService:Create(l, TweenInfo.new(0.85, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Position = l.Position - UDim2.fromScale(0, rise),
		TextTransparency = 1,
	})
	t:Play()
	local s = l:FindFirstChildOfClass("UIStroke")
	if s then
		TweenService:Create(s, TweenInfo.new(0.85), { Transparency = 1 }):Play()
	end
	t.Completed:Connect(function() l:Destroy() end)
end

-- one burst may cover many poops; stagger them so they read as a stream
function Popups.poopBurst(entries: { any })
	task.spawn(function()
		for i, e in ipairs(entries) do
			-- Exactly what the basket gained. This used to print the poop's cash VALUE,
			-- so a single poop worth 19 flashed "+19" while the basket moved by one.
			-- The value still decides whether it gets the big rainbow treatment.
			-- the rarity band decides the rainbow, not the cash value
			local rare = e.tier ~= nil and Config.rarityOf(e.tier) or "Common"
			Popups.poopGain(e.count or 1, rare == "Mythic" or rare == "Divine", e.tier)
			Audio.playVaried("PoopPlop", 0.15)
			if i % 3 == 0 then task.wait(0.05) end
		end
	end)
end

-- ── deposit: poop rain + banner ─────────────────────────────────────────────
function Popups.depositRain(count: number)
	if not layer then return end
	Audio.play("PoopDeposit")
	Audio.play("Confetti", { volume = 0.7 })

	-- "Deposited X Poops!" above the basket
	local banner = outlined(("Deposited %s Poops!"):format(Format.short(count)), 46, Color3.fromRGB(255, 236, 200))
	banner.Size = UDim2.fromOffset(760, 64)
	banner.AnchorPoint = Vector2.new(0.5, 0.5)
	banner.Position = UDim2.fromScale(0.5, 0.74)
	banner.ZIndex = 8
	banner.Parent = layer
	UIKit.pop(banner, 1.4)
	task.delay(1.4, function()
		if not banner.Parent then return end
		local t = TweenService:Create(banner, TweenInfo.new(0.5), { TextTransparency = 1 })
		local s = banner:FindFirstChildOfClass("UIStroke")
		if s then TweenService:Create(s, TweenInfo.new(0.5), { Transparency = 1 }):Play() end
		t:Play()
		t.Completed:Connect(function() banner:Destroy() end)
	end)

	-- poop icons raining down the screen
	task.spawn(function()
		for i = 1, 46 do
			local icon = Instance.new("ImageLabel")
			icon.BackgroundTransparency = 1
			icon.Image = IconManifest.ui.PoopBasket
			local sz = math.random(34, 66)
			icon.Size = UDim2.fromOffset(sz, sz)
			icon.Position = UDim2.new(math.random(), 0, -0.12, 0)
			icon.Rotation = math.random(-180, 180)
			icon.ZIndex = 3
			icon.Parent = layer
			local dur = 1.1 + math.random() * 0.9
			local t = TweenService:Create(icon, TweenInfo.new(dur, Enum.EasingStyle.Linear), {
				Position = UDim2.new(icon.Position.X.Scale + (math.random() - 0.5) * 0.1, 0, 1.15, 0),
				Rotation = icon.Rotation + math.random(-260, 260),
				ImageTransparency = 0.15,
			})
			t:Play()
			t.Completed:Connect(function() icon:Destroy() end)
			if i % 4 == 0 then task.wait(0.06) end
		end
	end)
end

-- ── discovery callout ─────────────────────────────────────────────────────
local discoveryQueue: { any } = {}
local discoveryRunning = false

local function showDiscovery(info: any)
	local screen = gui:FindFirstChild("DiscoveryPopup")
	if not screen then return end
	local container = screen:FindFirstChild("Container")
	if not container then return end

	local icon = container:FindFirstChild("ToiletIcon") :: ImageLabel?
	local nameLabel = container:FindFirstChild("ToiletName") :: TextLabel?
	local line = container:FindFirstChild("DiscoveryLine") :: TextLabel?

	if icon then icon.Image = IconManifest.icon(info.key, true) end
	if nameLabel then nameLabel.Text = info.name end
	if line then
		line.Text = ("You have discovered the %s %s!"):format(info.name, info.isMutation and "Mutation" or "Toilet")
	end

	screen.Enabled = true
	-- rarity escalates the size of the whole callout
	local weight = info.weight or 1
	local scale = UIKit.scaleOf(container)
	scale.Scale = 0.3
	TweenService:Create(scale, TweenInfo.new(0.5, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
		{ Scale = weight }):Play()

	Audio.play("Discovery", { volume = math.min(1, 0.6 + weight * 0.25) })

	-- spin the sparkle rays behind the icon
	local shine = container:FindFirstChild("Shine")
	local spinning = true
	if shine and shine:IsA("GuiObject") then
		task.spawn(function()
			while spinning and shine.Parent do
				shine.Rotation = (shine.Rotation + 0.6) % 360
				task.wait()
			end
		end)
	end

	task.wait(2.6 + weight * 0.4)
	spinning = false
	local out = TweenService:Create(scale, TweenInfo.new(0.25, Enum.EasingStyle.Back, Enum.EasingDirection.In),
		{ Scale = 0.2 })
	out:Play()
	out.Completed:Wait()
	screen.Enabled = false
	scale.Scale = 1
end

function Popups.discovery(info: any)
	table.insert(discoveryQueue, info)
	if discoveryRunning then return end
	discoveryRunning = true
	task.spawn(function()
		while #discoveryQueue > 0 do
			local next = table.remove(discoveryQueue, 1)
			local ok, err = pcall(showDiscovery, next)
			if not ok then warn("[Popups] discovery failed: " .. tostring(err)) end
		end
		discoveryRunning = false
	end)
end

-- ── toasts ──────────────────────────────────────────────────────────────
local TOAST_COLOR = {
	info   = Color3.fromRGB(255, 255, 255),
	error  = Color3.fromRGB(255, 110, 110),
	reward = Color3.fromRGB(120, 255, 140),
}
local activeToasts = 0

function Popups.toast(text: string, kind: string?)
	if not layer then return end
	if kind == "error" then Audio.play("Error") end
	local l = outlined(text, 34, TOAST_COLOR[kind or "info"] or TOAST_COLOR.info)
	l.Size = UDim2.fromOffset(900, 46)
	l.AnchorPoint = Vector2.new(0.5, 0)
	local slot = activeToasts
	activeToasts += 1
	l.Position = UDim2.new(0.5, 0, 0.16, slot * 50)
	l.ZIndex = 9
	l.Parent = layer
	UIKit.pop(l, 1.3)
	task.delay(2.2, function()
		if not l.Parent then return end
		local t = TweenService:Create(l, TweenInfo.new(0.4), { TextTransparency = 1 })
		local s = l:FindFirstChildOfClass("UIStroke")
		if s then TweenService:Create(s, TweenInfo.new(0.4), { Transparency = 1 }):Play() end
		t:Play()
		t.Completed:Connect(function()
			l:Destroy()
			activeToasts = math.max(0, activeToasts - 1)
		end)
	end)
end

-- ── tutorial celebration ──────────────────────────────────────────────────
-- `hooray` is opt-in: that sting is reserved for completing a tutorial step, so it
-- must not fire on the Lucky Block open, which reuses the same burst.
function Popups.confettiBurst(hooray: boolean?)
	if not layer then return end
	Audio.play("Confetti")
	if hooray then Audio.play("Hooray") end
	local COLORS = {
		Color3.fromRGB(255, 90, 90), Color3.fromRGB(90, 200, 255), Color3.fromRGB(120, 255, 130),
		Color3.fromRGB(255, 215, 60), Color3.fromRGB(220, 120, 255), Color3.fromRGB(255, 160, 60),
	}
	for _ = 1, 90 do
		local p = Instance.new("Frame")
		p.BackgroundColor3 = COLORS[math.random(#COLORS)]
		p.BorderSizePixel = 0
		p.Size = UDim2.fromOffset(math.random(8, 18), math.random(10, 22))
		p.Position = UDim2.fromScale(0.5, 0.5)
		p.Rotation = math.random(0, 360)
		p.ZIndex = 6
		p.Parent = layer
		local ang = math.random() * math.pi * 2
		local dist = 0.25 + math.random() * 0.5
		local t = TweenService:Create(p, TweenInfo.new(1.1 + math.random() * 0.5, Enum.EasingStyle.Quint, Enum.EasingDirection.Out), {
			Position = UDim2.fromScale(0.5 + math.cos(ang) * dist, 0.5 + math.sin(ang) * dist + 0.35),
			Rotation = p.Rotation + math.random(-400, 400),
			BackgroundTransparency = 1,
		})
		t:Play()
		t.Completed:Connect(function() p:Destroy() end)
	end
end

return Popups
