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
	-- Breathing room in design pixels. Pinned children would otherwise sit flush
	-- against the glass, which looks like the HUD is falling off the screen.
	local MARGIN = 28

	-- Resolve a UDim against the design span. The Figma export leaves floating-point
	-- noise in the scale terms (a child at x=1748 carries scale=-0.000154), so these
	-- must be FOLDED IN rather than compared to zero — testing `scale == 0` was false
	-- for every child, which silently skipped the whole pass.
	local function resolve(d: UDim, span: number): number
		return d.Scale * span + d.Offset
	end

	for _, child in ipairs(container:GetChildren()) do
		if child:IsA("GuiObject") then
			local pos, size, anchor = child.Position, child.Size, child.AnchorPoint
			local w = resolve(size.X, design.X)
			local h = resolve(size.Y, design.Y)
			-- top-left corner in design space, whatever the child's anchor is
			local left = resolve(pos.X, design.X) - anchor.X * w
			local top = resolve(pos.Y, design.Y) - anchor.Y * h

			local function axis(offset: number, extent: number, span: number): (number, UDim)
				local centre = offset + extent / 2
				local middle = span / 2
				if math.abs(centre - middle) < span * CENTRE_BAND then
					return 0.5, UDim.new(0.5, centre - middle)
				elseif centre > middle then
					-- far edge: position now refers to the child's far edge, and the gap
					-- to that edge never closes below the margin
					local gap = math.max(span - (offset + extent), MARGIN)
					return 1, UDim.new(1, -gap)
				end
				return 0, UDim.new(0, math.max(offset, MARGIN))
			end

			local ax, px = axis(left, w, design.X)
			local ay, py = axis(top, h, design.Y)
			child.AnchorPoint = Vector2.new(ax, ay)
			child.Position = UDim2.new(px.Scale, px.Offset, py.Scale, py.Offset)
			-- drop the scale noise from Size too, or the child rescales with the
			-- container now that the container is no longer the design size
			child.Size = UDim2.fromOffset(w, h)
		end
	end
end

-- `fill` widens the container to cover the whole viewport (the always-on HUD, whose
-- children belong on the screen edges). Panels leave it off and stay centred.
-- Gradient text, used by the lucky panel, the pickup numbers and the offline tag.
-- A UIGradient MULTIPLIES TextColor3, so anything it is applied to has to be white
-- underneath or the gradient comes out muddy -- UIKit.gradient handles that.
-- Fully saturated, and seven stops packed across the label rather than six spread
-- thin: the earlier set was mid-bright, so blended over a short word like "+30" it
-- washed out to pastel and you never really saw the spectrum.
UIKit.RAINBOW = ColorSequence.new({
	ColorSequenceKeypoint.new(0.00, Color3.fromRGB(255,  40,  60)),
	ColorSequenceKeypoint.new(0.17, Color3.fromRGB(255, 140,   0)),
	ColorSequenceKeypoint.new(0.33, Color3.fromRGB(255, 230,   0)),
	ColorSequenceKeypoint.new(0.50, Color3.fromRGB(  0, 220,  70)),
	ColorSequenceKeypoint.new(0.67, Color3.fromRGB(  0, 190, 255)),
	ColorSequenceKeypoint.new(0.83, Color3.fromRGB(130,  60, 255)),
	ColorSequenceKeypoint.new(1.00, Color3.fromRGB(255,   0, 190)),
})

function UIKit.gradient(label: TextLabel, seq: ColorSequence, rotation: number?)
	local grad = label:FindFirstChildOfClass("UIGradient")
	if not grad then
		grad = Instance.new("UIGradient")
		grad.Parent = label
	end
	grad.Color = seq
	grad.Rotation = rotation or 90
	label.TextColor3 = Color3.new(1, 1, 1)
	return grad
end

-- a two-stop gradient around one colour, light at the top and deep at the bottom
function UIKit.tintGradient(label: TextLabel, c: Color3, rotation: number?)
	return UIKit.gradient(label, ColorSequence.new(
		c:Lerp(Color3.new(1, 1, 1), 0.45),
		c:Lerp(Color3.new(0, 0, 0), 0.20)
	), rotation)
end

local MARGIN_CLOSE = 4
-- the largest share of the screen any single panel may occupy
local PANEL_MAX_WIDTH = 0.92
local PANEL_MAX_HEIGHT = 0.78

-- The Figma export hangs every panel's close button over the top-right corner --
-- measured on the Index at 4px past the right edge and 3px above the top. Panels
-- deliberately do not clip (clipping is what used to cut the corner off the button),
-- so that overhang simply shows.
--
-- Moving the BUTTON is what every earlier attempt did, and all of them looked wrong:
-- clamping it into the corner dropped it 9px below the title bar's centre, and
-- resizing it to fit the bar made it look tiny. The button is authored 114 tall,
-- centred on a 108 bar, and that relationship is the thing worth keeping.
--
-- So the FRAME grows instead. The panel widens by the overhang plus a little
-- padding, and the header row -- title bar and close button together, so their
-- alignment is untouched -- drops by the same amount to clear the top edge.
-- Idempotent: a button already inside changes nothing.
function UIKit.tuckCloseButton(container: GuiObject)
	local close = container:FindFirstChild("CloseButton", true)
	if not close or not close:IsA("GuiObject") then return end
	local panel = close.Parent
	if not panel or not panel:IsA("GuiObject") then return end

	local pw, ph = panel.Size.X.Offset, panel.Size.Y.Offset
	local w, h = close.Size.X.Offset, close.Size.Y.Offset
	if pw <= 0 or ph <= 0 or w <= 0 or h <= 0 then return end

	local ax, ay = close.AnchorPoint.X, close.AnchorPoint.Y
	local left = close.Position.X.Scale * pw + close.Position.X.Offset - ax * w
	local top = close.Position.Y.Scale * ph + close.Position.Y.Offset - ay * h

	local growRight = (left + w) + MARGIN_CLOSE - pw
	local dropDown = MARGIN_CLOSE - top

	if growRight > 0 then
		panel.Size = UDim2.new(panel.Size.X.Scale, pw + growRight, panel.Size.Y.Scale, ph)
		-- the Container is authored exactly the panel's size and drives the viewport
		-- fit, so it has to grow with it -- including the design size bindScale
		-- measured before any of this ran
		if container:IsA("GuiObject") and container.Size.X.Offset > 0 then
			container.Size = UDim2.new(
				container.Size.X.Scale, container.Size.X.Offset + growRight,
				container.Size.Y.Scale, container.Size.Y.Offset)
			local design = container:GetAttribute("DesignSize") :: Vector2?
			if design then
				container:SetAttribute("DesignSize", Vector2.new(design.X + growRight, design.Y))
			end
		end
	end

	if dropDown > 0 then
		local bar = panel:FindFirstChild("TitleBar")
		for _, item in ipairs({ close, bar }) do
			if item and item:IsA("GuiObject") then
				item.Position = UDim2.new(
					item.Position.X.Scale, item.Position.X.Offset,
					item.Position.Y.Scale, item.Position.Y.Offset + dropDown)
			end
		end
		panel.Size = UDim2.new(panel.Size.X.Scale, panel.Size.X.Offset,
			panel.Size.Y.Scale, panel.Size.Y.Offset + dropDown)
		if container:IsA("GuiObject") and container.Size.Y.Offset > 0 then
			container.Size = UDim2.new(
				container.Size.X.Scale, container.Size.X.Offset,
				container.Size.Y.Scale, container.Size.Y.Offset + dropDown)
			local design = container:GetAttribute("DesignSize") :: Vector2?
			if design then
				container:SetAttribute("DesignSize", Vector2.new(design.X, design.Y + dropDown))
			end
		end
	end
end

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
	UIKit.tuckCloseButton(container)

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
		-- ...but never past the point where the panel swallows the screen. Bound the
		-- scale by THIS panel's own design size so the result always leaves a margin,
		-- whatever the panel measures.
		--
		-- The height share is deliberately well under 1: the Lucky Block popups are
		-- authored 559 x 1120, TALLER than the 1080 design space itself, so fitting
		-- them to the viewport still filled it edge to edge. Panels that fit normally
		-- are untouched by this -- the Index is 760 tall, so its own fit is smaller
		-- than the bound and wins.
		if not fill then
			local d = container:GetAttribute("DesignSize") :: Vector2?
			-- A container authored at the full design space is a full-screen overlay
			-- (TutorialHud), not a dialog: bounding it to a share of the screen
			-- shrinks the whole layout and moves everything in it.
			local overlay = d ~= nil and d.X >= DESIGN.X * 0.98 and d.Y >= DESIGN.Y * 0.98
			if d and not overlay and d.X > 0 and d.Y > 0 then
				s = math.min(s, vp.X * PANEL_MAX_WIDTH / d.X, vp.Y * PANEL_MAX_HEIGHT / d.Y)
			end
		end
		(scale :: UIScale).Scale = s
		if fill then
			-- The UIScale multiplies the container's own size too, so asking for
			-- viewport/scale in design space renders as exactly the viewport: one
			-- uniform scale, no stretching, and the edges are the real screen edges.
			-- Pin the top-left rather than centring: the ScreenGui's usable area starts
			-- below the Roblox topbar, and centring pushed the container 58px above it,
			-- clipping the Home button off the top of the screen.
			container.AnchorPoint = Vector2.zero
			container.Position = UDim2.fromOffset(0, 0)
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
	-- The sheen is a rotated bar taller and wider than the button, swept across it.
	-- Parented straight onto the face it spills out over everything around the
	-- button, because panels deliberately do not clip (that is what stops the close
	-- button being cut off). So it goes in a mask of exactly the button's size that
	-- DOES clip, carrying the same rounded corner, and the sweep is trimmed to the
	-- button's own shape.
	local mask = Instance.new("Frame")
	mask.Name = "__FlashMask"
	mask.BackgroundTransparency = 1
	mask.BorderSizePixel = 0
	mask.Size = UDim2.fromScale(1, 1)
	mask.ClipsDescendants = true
	mask.ZIndex = 40

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
	if corner then
		local mc = Instance.new("UICorner")
		mc.CornerRadius = corner.CornerRadius
		mc.Parent = mask
	end
	mask.Parent = face
	shine.Parent = mask
	local t = TweenService:Create(shine, TweenInfo.new(0.35, Enum.EasingStyle.Quad),
		{ Position = UDim2.new(1.1, 0, -0.3, 0), BackgroundTransparency = 1 })
	t:Play()
	t.Completed:Connect(function() mask:Destroy() end)
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
