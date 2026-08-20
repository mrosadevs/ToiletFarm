--!strict
-- UIKit — the bubbly. Everything the Figma import needs to feel alive:
-- adaptive scaling, click targets, hover grow, press flash, bounce-in panels.

local TweenService = game:GetService("TweenService")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local GuiService = game:GetService("GuiService")

local UIKit = {}

-- The Figma frames were laid out at 1920x1080 in absolute pixels and carry a
-- FigBloxUIViewportScale UIScale. Driving that one object is what makes the whole
-- import responsive without touching a single child's position.
local DESIGN = Vector2.new(1920, 1080)

function UIKit.bindScale(screen: ScreenGui)
	local container = screen:FindFirstChild("Container")
	if not container then return end
	local scale = container:FindFirstChild("FigBloxUIViewportScale") :: UIScale?
	if not scale then
		scale = Instance.new("UIScale")
		scale.Name = "FigBloxUIViewportScale"
		scale.Parent = container
	end
	local function apply()
		local vp = screen.AbsoluteSize
		if vp.X <= 0 or vp.Y <= 0 then return end
		-- fit, never crop; phones end up small but nothing runs off-screen
		local s = math.min(vp.X / DESIGN.X, vp.Y / DESIGN.Y)
		-- on very narrow screens bump it up a little or the HUD is unreadable
		if vp.X < 700 then s *= 1.25 end
		(scale :: UIScale).Scale = s
	end
	apply()
	screen:GetPropertyChangedSignal("AbsoluteSize"):Connect(apply)
	return scale
end

-- ── click targets ─────────────────────────────────────────────────────────
-- The import is all Frames and ImageLabels, so overlay an invisible TextButton
-- rather than restructuring the Figma hierarchy.
function UIKit.hitbox(target: GuiObject): TextButton
	local existing = target:FindFirstChild("__Hit")
	if existing then return existing :: TextButton end
	local b = Instance.new("TextButton")
	b.Name = "__Hit"
	b.Size = UDim2.fromScale(1, 1)
	b.BackgroundTransparency = 1
	b.Text = ""
	b.AutoButtonColor = false
	b.ZIndex = 50
	b.Parent = target
	return b
end

-- ── motion ────────────────────────────────────────────────────────────────
local function scaleOf(o: GuiObject): UIScale
	local s = o:FindFirstChild("__Scale")
	if not s then
		s = Instance.new("UIScale")
		s.Name = "__Scale"
		s.Parent = o
	end
	return s :: UIScale
end
UIKit.scaleOf = scaleOf

local SPRING = TweenInfo.new(0.45, Enum.EasingStyle.Elastic, Enum.EasingDirection.Out)
local QUICK = TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

function UIKit.tweenScale(o: GuiObject, to: number, info: TweenInfo?)
	local s = scaleOf(o)
	local t = TweenService:Create(s, info or QUICK, { Scale = to })
	t:Play()
	return t
end

-- grow on hover, spring back off; shrink on press, overshoot on release
function UIKit.makeInteractive(target: GuiObject, onClick: (() -> ())?, opts: any?)
	opts = opts or {}
	local hoverScale = opts.hover or 1.06
	local pressScale = opts.press or 0.93
	local btn = UIKit.hitbox(target)
	scaleOf(target)

	local hovering = false
	btn.MouseEnter:Connect(function()
		hovering = true
		UIKit.tweenScale(target, hoverScale)
		if opts.onHover then opts.onHover() end
	end)
	btn.MouseLeave:Connect(function()
		hovering = false
		UIKit.tweenScale(target, 1, SPRING)
	end)
	btn.MouseButton1Down:Connect(function()
		UIKit.tweenScale(target, pressScale, TweenInfo.new(0.07))
	end)
	btn.MouseButton1Up:Connect(function()
		UIKit.tweenScale(target, hovering and hoverScale or 1, SPRING)
	end)
	btn.MouseButton1Click:Connect(function()
		UIKit.flash(target)
		if onClick then onClick() end
	end)
	return btn
end

-- a white sheen that sweeps across the face on click
function UIKit.flash(target: GuiObject)
	local face = target:FindFirstChild("Face") or target
	if not face:IsA("GuiObject") then face = target end
	local shine = Instance.new("Frame")
	shine.Name = "__Flash"
	shine.BackgroundColor3 = Color3.new(1, 1, 1)
	shine.BackgroundTransparency = 0.45
	shine.BorderSizePixel = 0
	shine.Size = UDim2.new(0.35, 0, 1.6, 0)
	shine.Position = UDim2.new(-0.4, 0, -0.3, 0)
	shine.Rotation = 14
	shine.ZIndex = 40
	local corner = (face :: any):FindFirstChildOfClass("UICorner")
	if corner then
		local c = Instance.new("UICorner")
		c.CornerRadius = corner.CornerRadius
		c.Parent = shine
	end
	shine.Parent = face
	local t = TweenService:Create(shine, TweenInfo.new(0.35, Enum.EasingStyle.Quad),
		{ Position = UDim2.new(1.1, 0, -0.3, 0), BackgroundTransparency = 1 })
	t:Play()
	t.Completed:Connect(function() shine:Destroy() end)
end

-- panels bounce in from small, and pop out on close
function UIKit.bounceIn(o: GuiObject, from: number?)
	local s = scaleOf(o)
	s.Scale = from or 0.55
	o.Visible = true
	TweenService:Create(s, TweenInfo.new(0.42, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
		{ Scale = 1 }):Play()
end

function UIKit.bounceOut(o: GuiObject, onDone: (() -> ())?)
	local s = scaleOf(o)
	local t = TweenService:Create(s, TweenInfo.new(0.2, Enum.EasingStyle.Back, Enum.EasingDirection.In),
		{ Scale = 0.5 })
	t:Play()
	t.Completed:Connect(function()
		o.Visible = false
		s.Scale = 1
		if onDone then onDone() end
	end)
end

-- a one-shot pop used for counters that just changed
function UIKit.pop(o: GuiObject, amount: number?)
	local s = scaleOf(o)
	s.Scale = amount or 1.18
	TweenService:Create(s, TweenInfo.new(0.3, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
		{ Scale = 1 }):Play()
end

-- ── misc ──────────────────────────────────────────────────────────────────
function UIKit.findFirst(root: Instance, name: string): any
	return root:FindFirstChild(name, true)
end

-- number that rolls up to its new value instead of snapping
function UIKit.rollNumber(label: TextLabel, from: number, to: number, format: (number) -> string, dur: number?)
	dur = dur or 0.35
	local t0 = os.clock()
	task.spawn(function()
		while true do
			local a = (os.clock() - t0) / (dur :: number)
			if a >= 1 or not label.Parent then break end
			label.Text = format(from + (to - from) * (1 - (1 - a) ^ 3))
			task.wait()
		end
		if label.Parent then label.Text = format(to) end
	end)
end

return UIKit
