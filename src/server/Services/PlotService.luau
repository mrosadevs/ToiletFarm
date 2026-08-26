--!strict
-- PlotService — hands each player one of the five islands, keeps the stall grid in step
-- with their slot count, and owns the physical toilet models sitting in those stalls.

local Players = game:GetService("Players")
local ServerStorage = game:GetService("ServerStorage")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.ToiletConfig)
local DataService = require(script.Parent.DataService)

local Assets = ServerStorage:WaitForChild("Assets")
local ToiletModels = Assets:WaitForChild("Toilets")
local MutationModels = Assets:WaitForChild("Mutations")

local PlotService = {}

local plotOf: { [Player]: Model } = {}
local ownerOf: { [Model]: Player } = {}
-- live toilet models, keyed by plot then slot
local placed: { [Model]: { [number]: Model } } = {}

function PlotService.plotFor(player: Player): Model?
	return plotOf[player]
end

function PlotService.ownerOfPlot(plot: Model): Player?
	return ownerOf[plot]
end

-- walk up from any descendant to the Plot model it belongs to
function PlotService.plotOfInstance(inst: Instance): Model?
	local n: Instance? = inst
	while n and n.Parent ~= workspace.Plots do
		n = n.Parent
		if n == nil or n == workspace then return nil end
	end
	return n :: Model?
end

-- Cached per plot and kind. mergeAll asks for the Merge pad to place its burst on,
-- and the Auto Merge gamepass calls mergeAll from a Heartbeat -- so this walked the
-- entire farm, poop heap included, potentially every frame. Pads are Studio-authored
-- and never created at runtime, so the answer cannot change.
local padsByKind: { [Model]: { [string]: { Model } } } = {}

function PlotService.padsOf(plot: Model, kind: string): { Model }
	local byKind = padsByKind[plot]
	if not byKind then
		byKind = {}
		for _, d in ipairs(plot:GetDescendants()) do
			if d:IsA("Model") then
				local k = d:GetAttribute("PadKind")
				if type(k) == "string" then
					byKind[k] = byKind[k] or {}
					table.insert(byKind[k], d)
				end
			end
		end
		padsByKind[plot] = byKind
	end
	return byKind[kind] or {}
end

function PlotService.padOf(plot: Model, kind: string): Model?
	return PlotService.padsOf(plot, kind)[1]
end

-- ── stalls ────────────────────────────────────────────────────────────────
-- fade-in tweens still running per stall, so a later hide can cancel them
local stallTweens: { [Model]: { Tween } } = {}

-- ── stacked stalls ───────────────────────────────────────────────────────
-- Two things were wrong with a stack of stalls, both visible from the hub island.
--
-- The rows are authored 8.75 studs apart while a stall is 8.25 tall, so every level
-- floated half a stud above the one below and the seam read as a gap. And the
-- reference the owner built (Workspace.StackedStalls) shows what a stack should look
-- like: flush, with two pillars at the FRONT of the lower stall carrying the one
-- above -- and no pillars at all when nothing is stacked on it.
--
-- Both are done here at boot rather than in Studio, so they hold for every plot and
-- survive whatever the place file happens to contain. Re-seating is idempotent: a
-- row already sitting flush is not moved.

-- taken off the owner's reference stall: how far forward of the side wall a pillar
-- stands, and how thick it is across and deep
local PILLAR_FORWARD = 2.25
local PILLAR_WIDTH = 0.57
local PILLAR_DEPTH = 0.75

-- The two side walls and the back wall are the three full-height parts. The side
-- walls are the matching pair; whatever is left is the back.
local function stallFrame(stall: Model): (Vector3?, Vector3?, { BasePart })
	local tall: { BasePart } = {}
	local tallest = 0
	for _, p in ipairs(stall:GetChildren()) do
		if p:IsA("BasePart") and p.Name ~= "ToiletSpot" then tallest = math.max(tallest, p.Size.Y) end
	end
	for _, p in ipairs(stall:GetChildren()) do
		if p:IsA("BasePart") and p.Name ~= "ToiletSpot" and math.abs(p.Size.Y - tallest) < 0.01 then
			table.insert(tall, p)
		end
	end
	if #tall < 3 then return nil, nil, {} end

	-- the pair with matching footprints are the sides; the odd one out is the back
	local sides: { BasePart } = {}
	local back: BasePart? = nil
	for _, a in ipairs(tall) do
		local matches = 0
		for _, b in ipairs(tall) do
			if a ~= b and (a.Size - b.Size).Magnitude < 0.01 then
				matches += 1
			end
		end
		if matches >= 1 then
			table.insert(sides, a)
		else
			back = a
		end
	end
	if #sides ~= 2 or not back then return nil, nil, {} end

	local centre = (sides[1].Position + sides[2].Position) / 2
	local away = centre - back.Position
	local forward = Vector3.new(away.X, 0, away.Z)
	if forward.Magnitude < 0.01 then return nil, nil, {} end
	return forward.Unit, centre, sides
end

local function buildPillars(stall: Model)
	if stall:FindFirstChild("Pillar1") then return end
	local forward, _, sides = stallFrame(stall)
	if not forward then
		warn(("[PlotService] could not read the frame of %s -- no pillars"):format(stall.Name))
		return
	end

	for i, wall in ipairs(sides) do
		local pos = wall.Position + forward * PILLAR_FORWARD
		local pillar = Instance.new("Part")
		pillar.Name = "Pillar" .. i
		pillar.Size = Vector3.new(PILLAR_WIDTH, wall.Size.Y, PILLAR_DEPTH)
		pillar.CFrame = CFrame.lookAt(pos, pos + forward)
		-- borrow the wall's look so a pillar is indistinguishable from the stall
		pillar.Material = wall.Material
		pillar.Color = wall.Color
		pillar.Anchored = true
		pillar.CanCollide = false
		pillar.CanQuery = false
		pillar.CastShadow = wall.CastShadow
		pillar.Transparency = 1
		pillar.Parent = stall
	end
end

-- Pillars are driven by the stall ABOVE, not by this one, so they are deliberately
-- excluded from setStallVisible.
local function setPillarsVisible(stall: Model, visible: boolean)
	for _, p in ipairs(stall:GetChildren()) do
		if p:IsA("BasePart") and p.Name:sub(1, 6) == "Pillar" then p.Transparency = visible and 0 or 1 end
	end
end

-- The map ships 4 rows of 12. Config.MAX_PLOT_SLOTS asks for more than that, so the
-- missing rows are cloned from the top row and stacked on, keeping slot numbering
-- column-aligned (slot + STALL_ROW is directly above) which the pillar mapping
-- depends on. Runs before the re-seat, so the new rows are spaced like the rest.
local function growStalls(plot: Model)
	local stalls = plot:FindFirstChild("Stalls")
	if not stalls then return end

	local existing = {}
	for _, s in ipairs(stalls:GetChildren()) do
		if s:IsA("Model") and s:GetAttribute("Slot") then table.insert(existing, s) end
	end
	if #existing == 0 or #existing >= Config.MAX_PLOT_SLOTS then return end

	table.sort(existing, function(a, b)
		return (a:GetAttribute("Slot") :: number) < (b:GetAttribute("Slot") :: number)
	end)

	local row = Config.STALL_ROW
	local _, _, sides = stallFrame(existing[1])
	local height = (#sides > 0) and sides[1].Size.Y or nil
	if not height then
		warn(("[PlotService] cannot read a stall's height on %s -- no extra rows"):format(plot.Name))
		return
	end

	local slot = #existing
	while slot < Config.MAX_PLOT_SLOTS do
		-- the stall `row` places back is the one directly below the new one
		local below = existing[slot - row + 1]
		if not below then break end
		local clone = below:Clone()
		slot += 1
		clone.Name = string.format("Stall_%02d", slot)
		clone:SetAttribute("Slot", slot)
		clone:SetAttribute("AboveSlot", nil)
		clone:SetAttribute("BelowSlot", nil)
		-- a clone of a lower stall carries its pillars; the stacking pass rebuilds
		-- them where they are actually needed
		for _, c in ipairs(clone:GetChildren()) do
			if c:IsA("BasePart") and c.Name:sub(1, 6) == "Pillar" then c:Destroy() end
		end
		for _, c in ipairs(clone:GetDescendants()) do
			if c:IsA("BasePart") then c.CastShadow = false end
		end
		clone:PivotTo(below:GetPivot() + Vector3.new(0, height, 0))
		clone.Parent = stalls
		table.insert(existing, clone)
	end
end

-- Rows flush, "which stall is above me" recorded, pillars built for anything that
-- has an upstairs neighbour.
local function stackStalls(plot: Model)
	local stalls = plot:FindFirstChild("Stalls")
	if not stalls then return end

	local rows: { [number]: { Model } } = {}
	local keys: { number } = {}
	for _, stall in ipairs(stalls:GetChildren()) do
		if stall:IsA("Model") then
			local y = math.floor(stall:GetPivot().Position.Y * 100 + 0.5) / 100
			if not rows[y] then
				rows[y] = {}
				table.insert(keys, y)
			end
			table.insert(rows[y], stall)
		end
	end
	if #keys < 2 then return end
	table.sort(keys)

	-- one stall's height is the spacing a flush stack wants
	local _, _, sides = stallFrame(rows[keys[1]][1])
	local height = (#sides > 0) and sides[1].Size.Y or nil
	if not height then return end

	local baseY = keys[1]
	for index, y in ipairs(keys) do
		local wantY = baseY + (index - 1) * height
		local delta = wantY - y
		if math.abs(delta) > 0.001 then
			for _, stall in ipairs(rows[y]) do
				stall:PivotTo(stall:GetPivot() + Vector3.new(0, delta, 0))
			end
		end
	end

	-- match each stall to the one directly above it and give it pillars
	for index = 1, #keys - 1 do
		for _, lower in ipairs(rows[keys[index]]) do
			local lp = lower:GetPivot().Position
			for _, upper in ipairs(rows[keys[index + 1]]) do
				local up = upper:GetPivot().Position
				if (Vector2.new(lp.X, lp.Z) - Vector2.new(up.X, up.Z)).Magnitude < 0.5 then
					lower:SetAttribute("AboveSlot", upper:GetAttribute("Slot"))
					-- and the reverse, so building into a stall can find the one holding
					-- it up without walking the whole plot
					upper:SetAttribute("BelowSlot", lower:GetAttribute("Slot"))
					buildPillars(lower)
					break
				end
			end
		end
	end
end

local function setStallVisible(stall: Model, visible: boolean, animate: boolean)
	if stall:GetAttribute("Unlocked") == visible then return end
	stall:SetAttribute("Unlocked", visible)

	-- A show tween left in flight keeps writing Transparency for 0.35s AFTER a hide
	-- has set it to 1. On a bulk buy the merge runs in the same frame as the buy, so
	-- stalls that had just been freed faded straight back in and stood there empty.
	-- Cancel anything still animating before applying the new state.
	local running = stallTweens[stall]
	if running then
		for _, tw in ipairs(running) do
			tw:Cancel()
		end
		stallTweens[stall] = nil
	end

	local tweens: { Tween } = {}
	for _, p in ipairs(stall:GetDescendants()) do
		-- pillars answer to the stall above, and ToiletSpot is a marker, not scenery
		if p:IsA("BasePart") and p.Name ~= "ToiletSpot" and p.Name:sub(1, 6) ~= "Pillar" then
			p.CanCollide = visible
			if animate and visible then
				p.Transparency = 1
				local tw = TweenService:Create(p, TweenInfo.new(0.35), { Transparency = 0 })
				tw:Play()
				table.insert(tweens, tw)
			else
				p.Transparency = visible and 0 or 1
			end
		end
	end
	stallTweens[stall] = (#tweens > 0) and tweens or nil
end

-- Called whenever slot `slot` gains or loses a toilet: the stall UNDER it is the one
-- whose pillars change. buildToilet/clearToilet drive the stalls directly rather than
-- going through refreshStalls, so without this the pillars only ever updated on a
-- rejoin.
local function refreshPillarsUnder(plot: Model, slot: number, occupied: boolean)
	local stalls = plot:FindFirstChild("Stalls")
	local changed = stalls and stalls:FindFirstChild(string.format("Stall_%02d", slot))
	local below = changed and changed:GetAttribute("BelowSlot") :: number?
	if not below then return end
	local lower = stalls and stalls:FindFirstChild(string.format("Stall_%02d", below))
	if lower then setPillarsVisible(lower :: Model, occupied) end
end

-- A stall only exists once a toilet stands in it — the plot grows with the farm
-- instead of showing a row of empty boxes on arrival.
function PlotService.refreshStalls(player: Player)
	local plot = plotOf[player]
	local p = DataService.get(player)
	if not plot or not p then return end
	local occupied: { [number]: boolean } = {}
	for _, t in ipairs(p.toilets) do
		occupied[t.slot] = true
	end
	for _, stall in ipairs(plot.Stalls:GetChildren()) do
		local slot = stall:GetAttribute("Slot") :: number
		setStallVisible(stall, occupied[slot] == true, true)
		-- a stall shows its pillars only while it is holding one up
		local above = stall:GetAttribute("AboveSlot") :: number?
		setPillarsVisible(stall, above ~= nil and occupied[above] == true)
	end
end

function PlotService.stall(plot: Model, slot: number): Model?
	return plot.Stalls:FindFirstChild(string.format("Stall_%02d", slot))
end

-- ── toilet models ─────────────────────────────────────────────────────────
local function applyMutationLook(model: Model, mut: string)
	if mut == "None" then return end
	local source = MutationModels:FindFirstChild("MUT_" .. mut)
	if not source then return end
	-- copy the Highlight and any ParticleEmitters off the mutation demo model
	local target = model.PrimaryPart or model:FindFirstChildWhichIsA("BasePart", true)
	if not target then return end
	for _, d in ipairs(source:GetDescendants()) do
		if d:IsA("Highlight") then
			local h = d:Clone()
			h.Adornee = model
			h.Parent = model
		elseif d:IsA("ParticleEmitter") then
			local a = target:FindFirstChild("MutFx") or Instance.new("Attachment")
			a.Name = "MutFx"
			a.Parent = target
			d:Clone().Parent = a
		end
	end
	if mut == "Rainbow" then
		local src = source:FindFirstChild("RainbowCycle", true)
		if src then src:Clone().Parent = model end
	end
end

function PlotService.buildToilet(plot: Model, slot: number, tier: number, mut: string): Model?
	-- Validate everything BEFORE revealing the stall. Bailing out after the reveal
	-- is the other way an empty stall ends up standing on the plot.
	local stall = PlotService.stall(plot, slot)
	if not stall then
		warn(("[PlotService] no stall for slot %d"):format(slot))
		return nil
	end
	local spot = stall:FindFirstChild("ToiletSpot") :: BasePart?
	if not spot then
		warn(("[PlotService] stall %d has no ToiletSpot"):format(slot))
		return nil
	end
	local source = ToiletModels:FindFirstChild(Config.assetId(tier))
	if not source then
		warn("[PlotService] missing toilet model " .. Config.assetId(tier))
		return nil
	end

	setStallVisible(stall, true, true)
	refreshPillarsUnder(plot, slot, true)

	placed[plot] = placed[plot] or {}
	local old = placed[plot][slot]
	if old then old:Destroy() end

	local model = source:Clone()
	model.Name = "Toilet"
	model:SetAttribute("Tier", tier)
	model:SetAttribute("Mutation", mut)
	model:SetAttribute("Slot", slot)
	for _, p in ipairs(model:GetDescendants()) do
		if p:IsA("BasePart") then
			p.Anchored = true
			p.CanCollide = false
			p.CanQuery = false
		end
	end

	-- Fit the model to the stall. These assets carry a ±90° yaw and pivots that are
	-- not at their bounding-box centre, so position by the BOUNDING BOX and normalise
	-- the rotation — placing by pivot alone drops them through the stall floor and
	-- sprawls them across their neighbours.
	local _, size = model:GetBoundingBox()
	local TARGET_HEIGHT = 4.2
	local TARGET_FOOT = 3.6
	local foot = math.max(size.X, size.Z)
	if size.Y > 0 and foot > 0 then
		-- whichever limit bites first, so nothing is too tall or too wide
		local k = math.min(TARGET_HEIGHT / size.Y, TARGET_FOOT / foot)
		-- ScaleTo is ABSOLUTE against the model's ORIGINAL authored size, not its
		-- current one, and these assets ship at wildly different scales
		-- (BurgerBowl is 0.0191, i.e. 249 studs across when authored). Passing a
		-- factor derived from the current size reset them to original x k, which is
		-- why the burger came out gigantic.
		model:ScaleTo(model:GetScale() * k)
	end
	local bcf
	bcf, size = model:GetBoundingBox()
	-- face the player, who stands in front of the row looking at the stalls
	local plotRot = plot:GetPivot().Rotation
	local targetCF = CFrame.new(spot.Position + Vector3.new(0, size.Y / 2 + 0.05, 0)) * plotRot
	model:PivotTo((targetCF * bcf:Inverse()) * model:GetPivot())

	applyMutationLook(model, mut)

	-- name plate over the stall
	local topCF, topSize = model:GetBoundingBox()
	local head = Instance.new("Part")
	head.Name = "NameAnchor"
	head.Size = Vector3.new(0.2, 0.2, 0.2)
	head.Transparency = 1
	head.Anchored = true
	head.CanCollide = false
	head.CanQuery = false
	head.CanTouch = false
	head.Massless = true
	head.CFrame = CFrame.new(topCF.Position + Vector3.new(0, topSize.Y / 2, 0))
	head.Parent = model
	do
		local bb = Instance.new("BillboardGui")
		bb.Name = "Nameplate"
		bb.Size = UDim2.fromScale(6, 2)
		bb.StudsOffsetWorldSpace = Vector3.new(0, 1.1, 0)
		bb.AlwaysOnTop = false
		bb.MaxDistance = 90
		local name = Instance.new("TextLabel")
		name.Size = UDim2.fromScale(1, 0.6)
		name.BackgroundTransparency = 1
		name.Font = Enum.Font.FredokaOne
		name.TextScaled = true
		name.TextColor3 = Config.RARITY_COLORS[Config.rarityOf(tier)]
		name.Text = (mut ~= "None" and (mut .. " ") or "") .. Config.displayName(tier)
		local stroke = Instance.new("UIStroke")
		stroke.Thickness = 2.5
		stroke.Color = Color3.new(0, 0, 0)
		stroke.Parent = name
		name.Parent = bb
		local tierLabel = Instance.new("TextLabel")
		tierLabel.Size = UDim2.fromScale(1, 0.34)
		tierLabel.Position = UDim2.fromScale(0, 0.62)
		tierLabel.BackgroundTransparency = 1
		tierLabel.Font = Enum.Font.FredokaOne
		tierLabel.TextScaled = true
		tierLabel.TextColor3 = Color3.fromRGB(235, 235, 235)
		tierLabel.Text = "Tier " .. tier
		local s2 = Instance.new("UIStroke")
		s2.Thickness = 2
		s2.Color = Color3.new(0, 0, 0)
		s2.Parent = tierLabel
		tierLabel.Parent = bb
		bb.Adornee = head
		bb.Parent = head
	end

	model.Parent = stall
	placed[plot][slot] = model

	-- pop-in bounce. ScaleTo is absolute against the model's ORIGINAL authored
	-- size, so the animation has to target the fitted scale, not 1 — ending on
	-- ScaleTo(1) restored every toilet to its raw asset size.
	local fitted = model:GetScale()
	model:ScaleTo(fitted * 0.01)
	task.spawn(function()
		local t0 = os.clock()
		while true do
			local a = (os.clock() - t0) / 0.32
			if a >= 1 or not model.Parent then break end
			-- overshoot then settle
			local e = 1 + 2.2 * (1 - a) ^ 2 * math.sin(a * 9)
			model:ScaleTo(math.max(0.01, fitted * a * e))
			task.wait()
		end
		if model.Parent then model:ScaleTo(fitted) end
	end)
	return model
end

function PlotService.toiletModel(plot: Model, slot: number): Model?
	return placed[plot] and placed[plot][slot] or nil
end

function PlotService.clearToilet(plot: Model, slot: number)
	local m = placed[plot] and placed[plot][slot]
	if m then
		m:Destroy()
		placed[plot][slot] = nil
	end
	local stall = PlotService.stall(plot, slot)
	if stall then setStallVisible(stall, false, false) end
	refreshPillarsUnder(plot, slot, false)
end

-- rebuild every physical toilet from the profile (join, rebirth, merge)
function PlotService.rebuild(player: Player)
	local plot = plotOf[player]
	local p = DataService.get(player)
	if not plot or not p then return end
	for slot, m in pairs(placed[plot] or {}) do
		m:Destroy()
		placed[plot][slot] = nil
	end
	for _, t in ipairs(p.toilets) do
		PlotService.buildToilet(plot, t.slot, t.tier, t.mut)
	end
	PlotService.refreshStalls(player)
end

-- lowest free slot within the player's current slot allowance
function PlotService.freeSlot(player: Player): number?
	local p = DataService.get(player)
	if not p then return nil end
	local used = {}
	for _, t in ipairs(p.toilets) do
		used[t.slot] = true
	end
	for s = 1, DataService.slots(player) do
		if not used[s] then return s end
	end
	return nil
end

-- ── claiming ────────────────────────────────────────────────────────────
-- the floor for the sign's height above the farm, used when a plot has no stalls
local SIGN_HEIGHT = 40

-- headshots are a web call, and the same handful of ids come back every time
local headshots: { [number]: string } = {}
local function headshotFor(userId: number): string?
	if headshots[userId] then return headshots[userId] end
	local ok, url = pcall(function()
		return Players:GetUserThumbnailAsync(
			userId,
			Enum.ThumbnailType.HeadShot,
			Enum.ThumbnailSize.Size150x150
		)
	end)
	if ok and type(url) == "string" then
		headshots[userId] = url
		return url
	end
	return nil
end

-- Where the farm's own sign hangs. It used to be the plot's bounding-box centre
-- plus 30% of its height, and that box takes in the 118 stud invisible border
-- barriers and the nine storey stall tower -- so the sign floated a hundred studs
-- up, off in the sky rather than over anybody's farm. Anchor on the BASE's centre
-- instead, lifted just clear of the stalls.
local function signCFrame(plot: Model): CFrame
	local base = plot:FindFirstChild("Base")
	local centre = base and base:GetPivot().Position or plot:GetPivot().Position

	-- High, above the stall tower: the point of this sign is telling you whose farm
	-- you are looking at from across the hub, so it has to clear the nine storeys of
	-- stalls rather than sit at head height where the tower hides it.
	local top = centre.Y + SIGN_HEIGHT
	local stalls = plot:FindFirstChild("Stalls")
	if stalls then
		for _, st in ipairs(stalls:GetChildren()) do
			if st:IsA("Model") then
				local cf, size = st:GetBoundingBox()
				top = math.max(top, cf.Position.Y + size.Y * 0.5)
			end
		end
	end
	return CFrame.new(Vector3.new(centre.X, top + 10, centre.Z))
end

local function nameplateFor(plot: Model, player: Player?)
	local sign = plot:FindFirstChild("OwnerSign")
	if not sign then
		sign = Instance.new("Part")
		sign.Name = "OwnerSign"
		sign.Size = Vector3.new(1, 1, 1)
		sign.Transparency = 1
		sign.Anchored = true
		sign.CanCollide = false
		sign.CanQuery = false
		sign.CastShadow = false

		local bb = Instance.new("BillboardGui")
		bb.Size = UDim2.fromScale(30, 6)
		bb.AlwaysOnTop = false
		bb.MaxDistance = 500

		-- headshot on the left, name to the right of it
		local avatar = Instance.new("ImageLabel")
		avatar.Name = "Avatar"
		avatar.AnchorPoint = Vector2.new(0, 0.5)
		avatar.Position = UDim2.fromScale(0.03, 0.5)
		-- Sized square outright rather than through a UIAspectRatioConstraint. Giving
		-- it a zero width and asking the constraint to derive one produced a 0x0 image
		-- on both DominantAxis settings; the billboard is a known 30x6 studs, so the
		-- square is just 0.88 of the height scaled by that 5:1 ratio.
		avatar.Size = UDim2.fromScale(0.88 * 6 / 30, 0.88)
		avatar.BackgroundColor3 = Color3.fromRGB(30, 30, 36)
		avatar.BackgroundTransparency = 0.25
		avatar.Visible = false
		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(1, 0)
		corner.Parent = avatar
		local ring = Instance.new("UIStroke")
		ring.Thickness = 3
		ring.Color = Color3.new(0, 0, 0)
		ring.Parent = avatar
		avatar.Parent = bb

		local lbl = Instance.new("TextLabel")
		lbl.Name = "Label"
		lbl.Size = UDim2.fromScale(1, 1)
		lbl.BackgroundTransparency = 1
		lbl.Font = Enum.Font.FredokaOne
		lbl.TextScaled = true
		lbl.TextColor3 = Color3.new(1, 1, 1)
		local st = Instance.new("UIStroke")
		st.Thickness = 3
		st.Color = Color3.new(0, 0, 0)
		st.Parent = lbl
		lbl.Parent = bb

		bb.Parent = sign
		sign.Parent = plot
	end

	sign.CFrame = signCFrame(plot)

	local lbl = sign:FindFirstChild("Label", true) :: TextLabel
	local avatar = sign:FindFirstChild("Avatar", true) :: ImageLabel?
	lbl.Text = player and (player.DisplayName .. "'s Farm") or "Empty Farm"
	lbl.TextColor3 = player and Color3.fromRGB(255, 255, 255) or Color3.fromRGB(170, 170, 170)

	if not avatar then return end
	if not player then
		avatar.Visible = false
		avatar.Image = ""
		-- nothing to sit beside, so the text takes the whole sign
		lbl.Position = UDim2.fromScale(0, 0)
		lbl.Size = UDim2.fromScale(1, 1)
		lbl.TextXAlignment = Enum.TextXAlignment.Center
		return
	end

	-- make room for the headshot whether or not the web call comes back
	lbl.Position = UDim2.fromScale(0.22, 0)
	lbl.Size = UDim2.fromScale(0.76, 1)
	lbl.TextXAlignment = Enum.TextXAlignment.Left

	local userId = player.UserId
	task.spawn(function()
		local url = headshotFor(userId)
		-- the plot may have changed hands while the thumbnail was in flight
		if url and avatar.Parent and ownerOf[plot] == player then
			avatar.Image = url
			avatar.Visible = true
		end
	end)
end

function PlotService.claim(player: Player): Model?
	-- GetChildren order is arbitrary, so claim by PlotIndex to keep it predictable
	local plots = workspace.Plots:GetChildren()
	table.sort(plots, function(a, b)
		return (a:GetAttribute("PlotIndex") or 99) < (b:GetAttribute("PlotIndex") or 99)
	end)
	for _, plot in ipairs(plots) do
		if plot:GetAttribute("OwnerUserId") == 0 then
			plot:SetAttribute("OwnerUserId", player.UserId)
			plotOf[player] = plot
			ownerOf[plot] = player
			nameplateFor(plot, player)
			return plot
		end
	end
	return nil
end

function PlotService.release(player: Player)
	local plot = plotOf[player]
	if not plot then return end
	plot:SetAttribute("OwnerUserId", 0)
	for slot, m in pairs(placed[plot] or {}) do
		m:Destroy()
	end
	placed[plot] = {}
	for _, stall in ipairs(plot.Stalls:GetChildren()) do
		setStallVisible(stall, false, false)
		setPillarsVisible(stall, false)
	end
	-- clear any world poop left behind
	local bin = plot:FindFirstChild("WorldPoops")
	if bin then bin:ClearAllChildren() end
	nameplateFor(plot, nil)
	ownerOf[plot] = nil
	plotOf[player] = nil
end

function PlotService.teleportToPlot(player: Player)
	local plot = plotOf[player]
	if not plot then return end
	local char = player.Character
	if not char then return end
	local hrp = char:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not hrp then return end

	local cf, size = plot:GetBoundingBox()
	local centre = cf.Position

	-- Land just off the Merge pad, facing it. This used to use the plot's bounding-box
	-- centre, but that centre drifts with the stall geometry, so players arrived in
	-- arbitrary spots. Standing ON the pad is still wrong (it would fire on arrival),
	-- so step back toward the open middle of the island by the pad's own half-width
	-- plus a margin.
	local base = plot:FindFirstChild("Base")
	local merge = base and base:FindFirstChild("MergePad")
	local plate = merge and (merge:FindFirstChild("Plate") or (merge :: Model).PrimaryPart) :: BasePart?

	local anchor, facing = centre, centre + plot:GetPivot().LookVector * -1
	if plate then
		-- horizontal direction from the pad toward the middle of the island
		local away = centre - plate.Position
		away = Vector3.new(away.X, 0, away.Z)
		away = away.Magnitude > 0.1 and away.Unit or (plot:GetPivot().LookVector * -1)
		local clearance = math.max(plate.Size.X, plate.Size.Z) * 0.5 + 5
		anchor = plate.Position + away * clearance
		facing = plate.Position
	end

	-- drop onto whatever ground is under it
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { char, plot:FindFirstChild("WorldPoops") }
	local from = Vector3.new(anchor.X, centre.Y + size.Y * 0.5 + 10, anchor.Z)
	local hit = workspace:Raycast(from, Vector3.new(0, size.Y + 60, 0) * -1, params)

	local target = hit and (hit.Position + Vector3.new(0, 4, 0)) or anchor
	hrp.CFrame = CFrame.lookAt(target, Vector3.new(facing.X, target.Y, facing.Z))
end

function PlotService.init()
	for _, plot in ipairs(workspace.Plots:GetChildren()) do
		plot:SetAttribute("OwnerUserId", 0)
		growStalls(plot)
		stackStalls(plot)
		for _, stall in ipairs(plot.Stalls:GetChildren()) do
			stall:SetAttribute("Unlocked", true) -- force setStallVisible to actually run
			setStallVisible(stall, false, false)
			setPillarsVisible(stall, false)
		end
		nameplateFor(plot, nil)
		local bin = Instance.new("Folder")
		bin.Name = "WorldPoops"
		bin.Parent = plot
	end

	Players.PlayerRemoving:Connect(function(player)
		PlotService.release(player)
	end)
end

return PlotService
