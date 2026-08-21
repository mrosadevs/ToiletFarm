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

-- The Figma children are absolute pixels measured from the container's top-left, so
-- on a container wider than the design they all stay bunched at the left. Convert
-- each one to the nearest edge (or the centre) once, so widening the container
-- pushes them out to the real screen edges instead of stranding them mid-screen.
function UIKit.pinEdges(container: GuiObject, design: Vector2)
	if container:GetAttribute("EdgesPinned") then return end
	container:SetAttribute("EdgesPinned", true)

	-- anything whose centre lands within this much of the middle stays centred
	local CENTRE_BAND = 0.10

	for _, child in ipairs(container:GetChildren()) do
		if child:IsA("GuiObject") then
			local pos, size = child.Position, child.Size
			-- only untouched, top-left anchored children are safe to re-anchor
			if pos.X.Scale == 0 and pos.Y.Scale == 0 and child.AnchorPoint == Vector2.zero then
				local w = size.X.Offset + size.X.Scale * design.X
				local h = size.Y.Offset + size.Y.Scale * design.Y

				local function axis(offset: number, extent: number, span: number): (number, UDim)
					local centre = offset + extent / 2
					local middle = span / 2
					if math.abs(centre - middle) < span * CENTRE_BAND then
						return 0.5, UDim.new(0.5, centre - middle)
					elseif centre > middle then
						-- far edge: position now refers to the child's far edge
						return 1, UDim.new(1, -(span - (offset + extent)))
					end
					return 0, UDim.new(0, offset)
				end

				local ax, px = axis(pos.X.Offset, w, design.X)
				local ay, py = axis(pos.Y.Offset, h, design.Y)
				child.AnchorPoint = Vector2.new(ax, ay)
				child.Position = UDim2.new(px.Scale, px.Offset, py.Scale, py.Offset)
			end
		end
	end
end

-- `fill` widens the container to cover the whole viewport (the always-on HUD, whose
-- children belong on the screen edges). Panels leave it off and stay centred.
function UIKit.bindScale(screen: ScreenGui, fill: boolean?)
	local container = screen:FindFirstChild("Container") :: GuiObject?
	if not container then return end

	-- the authored design size, captured before we ever resize it
	local design = container:GetAttribute("DesignSize") :: Vector2?
	if not design then
		design = Vector2.new(
			container.Size.X.Offset > 0 and container.Size.X.Offset or DESIGN.X,
			container.Size.Y.Offset > 0 and container.Size.Y.Offset or DESIGN.Y
		)
		container:SetAttribute("DesignSize", design)
	end

	-- Every panel sits in a Container exactly its own size, and the Container clips.
	-- That is what cuts the corner off the close button (worse once it grows on
	-- hover). Nothing useful is ever clipped at this level.
	container.ClipsDescendants = false

	if fill then UIKit.pinEdges(container, design :: Vector2) end

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
		if fill then
			-- The UIScale multiplies the container's own size too, so asking for
			-- viewport/scale in design space renders as exactly the viewport: one
			-- uniform scale, no stretching, and the edges are the real screen edges.
			container.AnchorPoint = Vector2.new(0.5, 0.5)
			container.Position = UDim2.fromScale(0.5, 0.5)
			container.Size = UDim2.fromOffset(vp.X / s, vp.Y / s)
		end
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
