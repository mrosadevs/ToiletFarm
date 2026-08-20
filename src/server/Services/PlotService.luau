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

function PlotService.padsOf(plot: Model, kind: string): { Model }
	local out = {}
	for _, d in ipairs(plot:GetDescendants()) do
		if d:IsA("Model") and d:GetAttribute("PadKind") == kind then
			table.insert(out, d)
		end
	end
	return out
end

function PlotService.padOf(plot: Model, kind: string): Model?
	return PlotService.padsOf(plot, kind)[1]
end

-- ── stalls ────────────────────────────────────────────────────────────────
-- fade-in tweens still running per stall, so a later hide can cancel them
local stallTweens: { [Model]: { Tween } } = {}

local function setStallVisible(stall: Model, visible: boolean, animate: boolean)
	if stall:GetAttribute("Unlocked") == visible then return end
	stall:SetAttribute("Unlocked", visible)

	-- A show tween left in flight keeps writing Transparency for 0.35s AFTER a hide
	-- has set it to 1. On a bulk buy the merge runs in the same frame as the buy, so
	-- stalls that had just been freed faded straight back in and stood there empty.
	-- Cancel anything still animating before applying the new state.
	local running = stallTweens[stall]
	if running then
		for _, tw in ipairs(running) do tw:Cancel() end
		stallTweens[stall] = nil
	end

	local tweens: { Tween } = {}
	for _, p in ipairs(stall:GetDescendants()) do
		if p:IsA("BasePart") and p.Name ~= "ToiletSpot" then
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

-- A stall only exists once a toilet stands in it — the plot grows with the farm
-- instead of showing a row of empty boxes on arrival.
function PlotService.refreshStalls(player: Player)
	local plot = plotOf[player]
	local p = DataService.get(player)
	if not plot or not p then return end
	local occupied: { [number]: boolean } = {}
	for _, t in ipairs(p.toilets) do occupied[t.slot] = true end
	for _, stall in ipairs(plot.Stalls:GetChildren()) do
		local slot = stall:GetAttribute("Slot") :: number
		setStallVisible(stall, occupied[slot] == true, true)
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
			a.Name = "MutFx"; a.Parent = target
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

	placed[plot] = placed[plot] or {}
	local old = placed[plot][slot]
	if old then old:Destroy() end

	local model = source:Clone()
	model.Name = "Toilet"
	model:SetAttribute("Tier", tier)
	model:SetAttribute("Mutation", mut)
	model:SetAttribute("Slot", slot)
	for _, p in ipairs(model:GetDescendants()) do
		if p:IsA("BasePart") then p.Anchored = true; p.CanCollide = false; p.CanQuery = false end
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
		stroke.Thickness = 2.5; stroke.Color = Color3.new(0, 0, 0); stroke.Parent = name
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
		s2.Thickness = 2; s2.Color = Color3.new(0, 0, 0); s2.Parent = tierLabel
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
	if m then m:Destroy(); placed[plot][slot] = nil end
	local stall = PlotService.stall(plot, slot)
	if stall then setStallVisible(stall, false, false) end
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
	for _, t in ipairs(p.toilets) do used[t.slot] = true end
	for s = 1, DataService.slots(player) do
		if not used[s] then return s end
	end
	return nil
end

-- ── claiming ────────────────────────────────────────────────────────────
local function nameplateFor(plot: Model, player: Player?)
	local sign = plot:FindFirstChild("OwnerSign")
	if not sign then
		sign = Instance.new("Part")
		sign.Name = "OwnerSign"
		sign.Size = Vector3.new(1, 1, 1)
		sign.Transparency = 1
		sign.Anchored = true; sign.CanCollide = false; sign.CanQuery = false
		local cf, size = plot:GetBoundingBox()
		sign.CFrame = CFrame.new(cf.Position + Vector3.new(0, size.Y * 0.30, 0))
		local bb = Instance.new("BillboardGui")
		bb.Size = UDim2.fromScale(26, 5)
		bb.AlwaysOnTop = false
		bb.MaxDistance = 500
		local lbl = Instance.new("TextLabel")
		lbl.Name = "Label"
		lbl.Size = UDim2.fromScale(1, 1)
		lbl.BackgroundTransparency = 1
		lbl.Font = Enum.Font.FredokaOne
		lbl.TextScaled = true
		lbl.TextColor3 = Color3.new(1, 1, 1)
		local st = Instance.new("UIStroke")
		st.Thickness = 3; st.Color = Color3.new(0, 0, 0); st.Parent = lbl
		lbl.Parent = bb
		bb.Parent = sign
		sign.Parent = plot
	end
	local lbl = sign:FindFirstChild("Label", true) :: TextLabel
	lbl.Text = player and (player.DisplayName .. "'s Farm") or "Empty Farm"
	lbl.TextColor3 = player and Color3.fromRGB(255, 255, 255) or Color3.fromRGB(170, 170, 170)
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
	for slot, m in pairs(placed[plot] or {}) do m:Destroy() end
	placed[plot] = {}
	for _, stall in ipairs(plot.Stalls:GetChildren()) do
		setStallVisible(stall, false, false)
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
	-- Land in the MIDDLE of the island, not on a pad: spawning on the merge pad
	-- fired it the instant you arrived.
	local cf, size = plot:GetBoundingBox()
	local centre = cf.Position

	-- drop onto whatever ground is under the centre
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { char, plot:FindFirstChild("WorldPoops") }
	local from = Vector3.new(centre.X, centre.Y + size.Y * 0.5 + 10, centre.Z)
	local hit = workspace:Raycast(from, Vector3.new(0, size.Y + 60, 0) * -1, params)

	local target = hit and (hit.Position + Vector3.new(0, 4, 0)) or centre
	-- face the stalls, which sit toward the plot's +Z
	hrp.CFrame = CFrame.lookAt(target, target + plot:GetPivot().LookVector * -1)
end

function PlotService.init()
	for _, plot in ipairs(workspace.Plots:GetChildren()) do
		plot:SetAttribute("OwnerUserId", 0)
		for _, stall in ipairs(plot.Stalls:GetChildren()) do
			stall:SetAttribute("Unlocked", true)   -- force setStallVisible to actually run
			setStallVisible(stall, false, false)
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
