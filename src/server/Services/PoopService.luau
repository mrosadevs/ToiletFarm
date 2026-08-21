--!strict
-- PoopService — world poop instances and the pickup loop.
-- Poop accumulates on the floor and walking near it collects it into your carry
-- pile. There is no cap on that pile; the only bound is the world-poop population
-- per plot, which drop() trims so a farm never fills up with physics parts.

local Players = game:GetService("Players")
local ServerStorage = game:GetService("ServerStorage")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Debris = game:GetService("Debris")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.ToiletConfig)
local Net = require(Shared.Net)
local DataService = require(script.Parent.DataService)
local PlotService = require(script.Parent.PlotService)
local PassService = require(script.Parent.PassService)

local PoopModels = ServerStorage.Assets:WaitForChild("Poops")
local MutationPoops = ServerStorage.Assets:WaitForChild("MutationPoops")

local PickupEvent = Net.event(Net.NAMES.PoopPickup)

local PoopService = {}

-- cached stand-ins, so we're not rebuilding a model hundreds of times
local templateCache: { [string]: BasePart } = {}

-- how big a poop reads on the belt; Micro is tiny and Mega is huge on purpose
local function targetSize(tier: number): number
	return (tier == 21 and 0.9) or (tier == 22 and 2.7) or 1.7
end

-- Every *_Poop model sets PrimaryPart to the SAME generic poop mesh
-- (rbxassetid://118664197075805) — what makes a Rusty Pan look like a rusty pan is
-- the *sibling* parts next to it. Cloning the PrimaryPart alone therefore dropped a
-- plain brown lump for all 30 tiers. So keep the whole model, welded into one rigid
-- body: the root still behaves as a single physics object on the conveyor, and the
-- decoration parts ride along non-collidable so heaps still stack without gaps.
local function buildTemplate(tier: number): BasePart
	local source = PoopModels:FindFirstChild(Config.assetId(tier) .. "_Poop")
	if not source or not source:IsA("Model") then
		local p = Instance.new("Part")
		p.Shape = Enum.PartType.Ball
		p.Size = Vector3.new(1.5, 1.5, 1.5)
		p.Color = Color3.fromRGB(105, 70, 40)
		return p
	end

	local model = source:Clone()
	-- Highlights and GUIs ride along on a clone and paint over the mutation FX we
	-- add afterwards, so strip them here rather than per-drop.
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("Highlight") or d:IsA("BillboardGui") or d:IsA("SurfaceGui")
			or d:IsA("Script") or d:IsA("LocalScript") or d:IsA("ProximityPrompt") then
			d:Destroy()
		end
	end

	local root = model.PrimaryPart
	if not root then
		local bestVol = 0
		for _, d in ipairs(model:GetDescendants()) do
			if d:IsA("BasePart") then
				local v = d.Size.X * d.Size.Y * d.Size.Z
				if v > bestVol then bestVol, root = v, d end
			end
		end
	end
	if not root then
		model:Destroy()
		local p = Instance.new("Part")
		p.Shape = Enum.PartType.Ball
		p.Size = Vector3.new(1.5, 1.5, 1.5)
		p.Color = Color3.fromRGB(105, 70, 40)
		return p
	end

	-- scale the whole assembly, not just the root, or the decorations detach
	local extents = model:GetExtentsSize()
	local dim = math.max(extents.X, extents.Y, extents.Z)
	local k = dim > 0 and (targetSize(tier) / dim) or 1

	-- record placements relative to the root before anything moves
	local placed: { { part: BasePart, rel: CFrame, size: Vector3 } } = {}
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("BasePart") then
			-- keep the rotation, scale only the offset from the root
			local rel = root.CFrame:ToObjectSpace(d.CFrame)
			local scaled = CFrame.new(rel.Position * k) * (rel - rel.Position)
			table.insert(placed, { part = d, rel = scaled, size = d.Size })
		end
	end
	root.CFrame = CFrame.new()
	for _, e in ipairs(placed) do
		e.part.Size = e.size * k
		if e.part ~= root then e.part.CFrame = e.rel end
	end

	for _, e in ipairs(placed) do
		local part = e.part
		local isRoot = part == root
		-- Physics body, not a scripted mover. The belts are anchored parts with a
		-- Velocity, so a free body resting on one is carried along for free.
		part.Anchored = false
		part.CanQuery = false
		-- only the root collides and is touchable; decorations are cosmetic, so an
		-- irregular silhouette can never wedge a poop on the belt
		part.CanCollide = isRoot
		part.CanTouch = isRoot
		part.Massless = not isRoot
		-- Collide as a BOX, never as the mesh. Irregular mesh collision is what
		-- leaves visible gaps between poops in a heap.
		if part:IsA("MeshPart") then
			pcall(function() part.CollisionFidelity = Enum.CollisionFidelity.Box end)
		end
		-- density 1, LOW friction so they flow into a pile instead of sticking where
		-- they land, zero elasticity so they do not bounce around
		part.CustomPhysicalProperties = PhysicalProperties.new(1, 0.2, 0)
		part.CollisionGroup = "Poop"
	end

	for _, e in ipairs(placed) do
		if e.part ~= root then
			-- A WeldConstraint does NOT drag its Part1 when Part0.CFrame is assigned
			-- directly, and drop() places every poop by assigning root.CFrame. That
			-- left each decoration stranded ~65 studs away, so all 30 tiers rendered
			-- as the bare stock poop no matter which model they came from. A Weld
			-- derives Part1 rigidly from Part0 * C0, so the assembly moves as one.
			local weld = Instance.new("Weld")
			weld.Part0 = root
			weld.Part1 = e.part
			weld.C0 = e.rel
			weld.Parent = root
			e.part.Parent = root
		end
	end

	root.Parent = nil
	model:Destroy()
	return root
end

local function templateFor(tier: number, mut: string): BasePart
	local cacheKey = tier .. "|" .. mut
	local cached = templateCache[cacheKey]
	if cached then return cached end

	local final = buildTemplate(tier)
	if mut ~= "None" then
		local mutSource = MutationPoops:FindFirstChild("MUT_" .. mut .. "_Poop")
		if mutSource then
			for _, d in ipairs(mutSource:GetDescendants()) do
				if d:IsA("Highlight") then
					local h = d:Clone(); h.Adornee = nil; h.Parent = final
				elseif d:IsA("ParticleEmitter") then
					local a = final:FindFirstChild("Fx") or Instance.new("Attachment")
					a.Name = "Fx"; a.Parent = final
					d:Clone().Parent = a
				end
			end
		end
	end

	templateCache[cacheKey] = final
	return final
end

-- ── the conveyor route ─────────────────────────────────────────────────────
-- A poop drops in front of its toilet onto the belt running along the stall row,
-- rides it inward to the centre channel, then travels down the funnel and comes to
-- rest in front of the Merge pad, where the player walks over it to collect.
-- All coordinates are in the plot's own space, so this works on every island.
local BELT_SPEED = 14      -- studs/sec along the side belts
local MIDDLE_SPEED = 12
local FALL_TIME = 0.32

local function localToWorld(plot: Model, x: number, y: number, z: number): Vector3
	return plot:GetPivot():PointToWorldSpace(Vector3.new(x, y, z))
end

-- The route used to seat poops on named guide parts, but those do not always match
-- the geometry the player sees: the stall platforms are invisible markers and the
-- collection area has a visible floor 0.325 above its guide. Raycasting for the
-- real surface fixes both, and keeps working if a belt is moved in Studio.
local surfaceParams = RaycastParams.new()
surfaceParams.FilterType = Enum.RaycastFilterType.Exclude
local function surfaceLocalY(plot: Model, ignore: Instance, x: number, z: number, fromLocalY: number): number?
	local filter = { ignore }
	for _, pl in ipairs(game:GetService("Players"):GetPlayers()) do
		if pl.Character then table.insert(filter, pl.Character) end
	end
	surfaceParams.FilterDescendantsInstances = filter
	local from = localToWorld(plot, x, fromLocalY, z)
	local hit = workspace:Raycast(from, Vector3.new(0, -90, 0), surfaceParams)
	if not hit then return nil end
	return plot:GetPivot():PointToObjectSpace(hit.Position).Y
end

-- Reads the route off the named parts in the plot rather than hard-coding numbers,
-- so moving a belt in Studio moves the poop path with it.
local routeCache: { [Model]: any } = {}

local function routeOf(plot: Model)
	local cached = routeCache[plot]
	if cached then return cached end
	local base = plot:FindFirstChild("Base")
	if not base then return nil end
	local left   = base:FindFirstChild("LeftSideConveyor")
	local right  = base:FindFirstChild("RightSideConveyor")
	local middle = base:FindFirstChild("MiddleConveyor")
	local collect = base:FindFirstChild("CollectionArea")
	if not (left and right and middle and collect) then return nil end

	local cf = plot:GetPivot()
	-- world-axis extents of a part expressed in the plot's own frame
	local function box(part: BasePart)
		local c = cf:PointToObjectSpace(part.Position)
		local rel = cf:Inverse() * part.CFrame
		local ext = Vector3.new(
			math.abs(rel.XVector.X) * part.Size.X + math.abs(rel.YVector.X) * part.Size.Y + math.abs(rel.ZVector.X) * part.Size.Z,
			math.abs(rel.XVector.Y) * part.Size.X + math.abs(rel.YVector.Y) * part.Size.Y + math.abs(rel.ZVector.Y) * part.Size.Z,
			math.abs(rel.XVector.Z) * part.Size.X + math.abs(rel.YVector.Z) * part.Size.Y + math.abs(rel.ZVector.Z) * part.Size.Z
		) * 0.5
		return { c = c, e = ext, top = c.Y + ext.Y }
	end

	local L, R, M, C = box(left), box(right), box(middle), box(collect)
	local route = {
		left = L, right = R, middle = M, collect = C,
		-- the belts meet the middle conveyor at its centre X
		centreX = M.c.X,
		-- where a poop lands after falling off the stall platform
		sideZ = L.c.Z,
		sideTop = L.top,
		middleTop = M.top,
		collectTop = C.top,
		-- the middle belt runs forward (toward the player) into the collection area
		middleFromZ = M.c.Z + M.e.Z,
		middleToZ = M.c.Z - M.e.Z,
		collectZ = C.c.Z,
		collectHalf = Vector3.new(C.e.X, 0, C.e.Z),
	}
	routeCache[plot] = route
	return route
end

-- Drives one poop: off the front of its stall, onto the side belt, inward to the
-- middle belt, forward down the middle belt, then into the collection area.
local function runRoute(plot: Model, part: BasePart, startLocal: Vector3, spin: CFrame)
	local route = routeOf(plot)
	if not route then
		part:SetAttribute("InTransit", false)
		return
	end

	local half = part.Size.Y * 0.5
	local roll = 0

	-- Per-poop variation. Without this every poop travelled the exact centre line at
	-- the exact same speed, which is what made the belt look mechanical.
	local lane = (math.random() - 0.5) * 2.4        -- offset across the belt
	local speedMul = 0.82 + math.random() * 0.36    -- so they bunch and spread out
	local swayPhase = math.random() * 6.28
	local rollRate = (0.6 + math.random() * 0.7) * (math.random() < 0.5 and -1 or 1)

	-- The poop tumbles as it travels, so its vertical extent changes every frame.
	-- Seating it with a fixed Size.Y/2 left it hanging in the air above the belt.
	-- `y` is now the SURFACE the poop rests on; the centre offset is derived from
	-- the rotation actually being applied.
	local function halfFor(rot)
		local s = part.Size * 0.5
		return math.abs(rot.XVector.Y) * s.X
		     + math.abs(rot.YVector.Y) * s.Y
		     + math.abs(rot.ZVector.Y) * s.Z
	end

	local function place(x, ySurface, z, extraSpin)
		-- bail the moment it is picked up, so the route stops fighting the
		-- fly-to-player animation for the CFrame
		if not part.Parent or part:GetAttribute("Collected") then return false end
		local rot = spin * (extraSpin or CFrame.identity)
		part.CFrame = CFrame.new(localToWorld(plot, x, ySurface + halfFor(rot), z)) * rot
		return true
	end

	-- the drop origin is a centre; convert it to the surface the poop sits on
	local startSurface = startLocal.Y - half

	-- a short ballistic fall between two points, used at each drop in the route
	local function fall(fromX, fromY, fromZ, toX, toY, toZ, dur, arc)
		local t0 = os.clock()
		while true do
			local a = (os.clock() - t0) / dur
			if a >= 1 then break end
			-- no tumble: poops slide, they do not roll
			local x = fromX + (toX - fromX) * a
			local z = fromZ + (toZ - fromZ) * a
			-- ease-in on Y so it reads as gravity rather than a lerp
			local y = fromY + (toY - fromY) * (a * a) + math.sin(a * math.pi) * (arc or 0)
			if not place(x, y, z) then return false end
			task.wait()
		end
		return true
	end

	-- 1a. slide forward off the stall to the lip of the platform, settling onto the
	--     floor that is really under the toilet rather than a fixed 0.5 stud drop
	local lipZ = route.sideZ + route.left.e.Z + 1.5
	local bin = part.Parent
	local floorY = surfaceLocalY(plot, bin, startLocal.X, startLocal.Z, startLocal.Y + 3) or (startSurface - 0.5)
	local t0 = os.clock()
	while true do
		local a = (os.clock() - t0) / 0.28
		if a >= 1 then break end
		local z = startLocal.Z + (lipZ - startLocal.Z) * a
		local y = startSurface + (floorY - startSurface) * math.min(1, a * 1.6)
		if not place(startLocal.X, y, z) then return end
		task.wait()
	end
	local lipSurface = surfaceLocalY(plot, bin, startLocal.X, lipZ, startLocal.Y + 3) or floorY

	-- 1b. drop off the lip onto the side belt below
	local sideY = surfaceLocalY(plot, bin, startLocal.X, route.sideZ, startLocal.Y + 3) or route.sideTop
	if not fall(startLocal.X, lipSurface, lipZ,
	            startLocal.X, sideY, route.sideZ, FALL_TIME, 0.25) then return end

	-- 2. ride the side belt inward. Left belt (+X side) runs toward -X, right belt
	--    (-X side) runs toward +X; both feed the middle belt.
	local x = startLocal.X
	local dir = (x > route.centreX) and -1 or 1
	local rideY = sideY
	local laneZ = route.sideZ + lane
	while math.abs(x - route.centreX) > 0.5 do
		local dt = task.wait()
		x += dir * BELT_SPEED * speedMul * dt
		if (dir > 0 and x > route.centreX) or (dir < 0 and x < route.centreX) then x = route.centreX end
		-- The side conveyors are sloped, so their surface height changes along X.
		-- Seating on route.sideTop (a bounding-box top) left the poop floating up
		-- to 2.9 studs. Follow whatever is actually underneath instead.
		local surf = surfaceLocalY(plot, bin, x, laneZ, rideY + 5)
		if surf and surf < rideY then rideY = surf end
		-- a lazy sway and roll: halfFor() derives the seat height from the rotation
		-- being applied, so tilting it never lifts it off the belt
		roll += rollRate * dt
		local sway = math.sin(swayPhase + os.clock() * 1.4) * 0.28
		if not place(x, rideY, laneZ + sway, CFrame.Angles(0, 0, roll)) then return end
	end
	sideY = rideY

	-- 3. drop onto the middle belt
	-- Join the middle belt where the two actually meet. Dropping at middleFromZ (the
	-- belt's far end) made the poop travel back up the belt before conveying forward.
	local joinZ = math.clamp(route.sideZ, route.middleToZ, route.middleFromZ)
	local midX = route.centreX + lane * 0.5
	local midY = surfaceLocalY(plot, bin, midX, joinZ, sideY + 5) or route.middleTop
	-- a short, almost flat step down: it is a junction, not a launch
	if not fall(route.centreX, sideY, route.sideZ,
	            midX, midY, joinZ, 0.20, 0.06) then return end

	-- 4. the middle belt carries it forward, toward the player, into the collection area
	local z = joinZ
	local runY = midY
	while z > route.middleToZ do
		local dt = task.wait()
		z -= MIDDLE_SPEED * speedMul * dt
		if z < route.middleToZ then z = route.middleToZ end
		local surf = surfaceLocalY(plot, bin, midX, z, runY + 5)
		if surf and surf < runY then runY = surf end
		roll += rollRate * dt * 0.8
		local sway = math.sin(swayPhase + os.clock() * 1.6) * 0.2
		if not place(midX + sway, runY, z, CFrame.Angles(roll, 0, 0)) then return end
	end
	midY = runY

	-- 5. off the end of the belt and into the collection area under REAL PHYSICS.
	-- Hand-placing a stack height never matched the geometry — these are irregular
	-- meshes, so a computed offset left visible gaps between them. Letting them drop
	-- and settle means the area fills from the bottom and backs up on its own.
	if not part.Parent or part:GetAttribute("Collected") then return end
	part:SetAttribute("InTransit", false)
	part.Massless = false
	part.CanCollide = true
	part.CanTouch = true
	-- dense and grippy so the heap settles quickly instead of skating about
	part.CustomPhysicalProperties = PhysicalProperties.new(1.2, 0.9, 0.05, 1, 1)
	part.Anchored = false
	-- Thrown off the end at belt speed, with a little sideways scatter, so they carry
	-- across the floor and fill it before the heap starts backing up toward the belt.
	local pivot = plot:GetPivot()
	local travel = pivot.LookVector
	local across = pivot.RightVector
	part.AssemblyLinearVelocity = travel * MIDDLE_SPEED
		+ across * ((math.random() - 0.5) * 5)
		+ Vector3.new(0, -1, 0)
	part.AssemblyAngularVelocity = Vector3.new(
		(math.random() - 0.5) * 6, (math.random() - 0.5) * 6, (math.random() - 0.5) * 6)
end

-- ── spawning ────────────────────────────────────────────────────────────
-- Same journey as a poop, for anything that is a Model rather than a single part
-- (Lucky Blocks). Deliberately a separate walk rather than a refactor of runRoute:
-- the poop seating was tuned against the real sloped surfaces and is not worth
-- destabilising. `onArrive` fires once the model is at rest.
function PoopService.rideConveyor(plot: Model, model: Model, origin: Vector3, onArrive: (() -> ())?)
	local route = routeOf(plot)
	if not route then
		if onArrive then onArrive() end
		return
	end

	local startLocal = plot:GetPivot():PointToObjectSpace(origin)
	local _, size = model:GetBoundingBox()
	local half = size.Y * 0.5
	local spinT = 0

	-- place by SURFACE height, with a slow spin so it still reads as a pickup
	local function place(x: number, ySurface: number, z: number, dt: number?): boolean
		if not model.Parent then return false end
		spinT += (dt or 0)
		model:PivotTo(CFrame.new(localToWorld(plot, x, ySurface + half, z)) * CFrame.Angles(0, spinT * 1.6, 0))
		return true
	end

	local function glide(fromX, fromY, fromZ, toX, toY, toZ, dur, arc): boolean
		local t0 = os.clock()
		while true do
			local a = (os.clock() - t0) / dur
			if a >= 1 then break end
			local x = fromX + (toX - fromX) * a
			local z = fromZ + (toZ - fromZ) * a
			local y = fromY + (toY - fromY) * (a * a) + math.sin(a * math.pi) * (arc or 0)
			if not place(x, y, z, 1 / 60) then return false end
			task.wait()
		end
		return true
	end

	-- 1. off the stall lip and down onto the side belt
	local lipZ = route.sideZ + route.left.e.Z + 1.5
	local startSurface = startLocal.Y - half
	local sideY = surfaceLocalY(plot, model, startLocal.X, route.sideZ, startLocal.Y + 4) or route.sideTop
	if not glide(startLocal.X, startSurface, startLocal.Z, startLocal.X, startSurface - 0.4, lipZ, 0.28, 0) then return end
	if not glide(startLocal.X, startSurface - 0.4, lipZ, startLocal.X, sideY, route.sideZ, FALL_TIME, 0.3) then return end

	-- 2. inward along the side belt
	local x = startLocal.X
	local dir = (x > route.centreX) and -1 or 1
	local rideY = sideY
	while math.abs(x - route.centreX) > 0.5 do
		local dt = task.wait()
		x += dir * BELT_SPEED * dt
		if (dir > 0 and x > route.centreX) or (dir < 0 and x < route.centreX) then x = route.centreX end
		local surf = surfaceLocalY(plot, model, x, route.sideZ, rideY + 5)
		if surf and surf < rideY then rideY = surf end
		if not place(x, rideY, route.sideZ, dt) then return end
	end

	-- 3. step down onto the middle belt where the two actually meet
	local joinZ = math.clamp(route.sideZ, route.middleToZ, route.middleFromZ)
	local midY = surfaceLocalY(plot, model, route.centreX, joinZ, rideY + 5) or route.middleTop
	if not glide(route.centreX, rideY, route.sideZ, route.centreX, midY, joinZ, 0.2, 0.06) then return end

	-- 4. forward down the middle belt into the collection area
	local z = joinZ
	local runY = midY
	while z > route.middleToZ do
		local dt = task.wait()
		z -= MIDDLE_SPEED * dt
		if z < route.middleToZ then z = route.middleToZ end
		local surf = surfaceLocalY(plot, model, route.centreX, z, runY + 5)
		if surf and surf < runY then runY = surf end
		if not place(route.centreX, runY, z, dt) then return end
	end

	-- 5. settle in the collection area, where the player walks into it
	local restX = route.centreX + (math.random() - 0.5) * math.max(2, route.collectHalf.X)
	local restZ = route.collectZ + (math.random() - 0.5) * math.max(2, route.collectHalf.Z)
	local restY = surfaceLocalY(plot, model, restX, restZ, runY + 4) or route.collectTop
	if not glide(route.centreX, runY, route.middleToZ, restX, restY, restZ, 0.3, 0.4) then return end
	if not place(restX, restY, restZ, 0) then return end

	if onArrive then onArrive() end
end

-- Where a poop should actually appear: same X as its toilet, but pushed out to the
-- near edge of the side belt and lifted, so it visibly falls onto the belt.
--
-- It cannot spawn inside the stall. The stalls have a front lip and tall side walls;
-- the reference game only clears them because every nest has its own small conveyor
-- pushing the egg out. We have no such part, so a poop spawned inside just sits there.
local dropCache: { [Model]: { z: number, y: number } } = {}

local function dropPointFor(plot: Model, origin: Vector3): Vector3
	local pcf = plot:GetPivot()
	local localOrigin = pcf:PointToObjectSpace(origin)

	local cached = dropCache[plot]
	if not cached then
		local base = plot:FindFirstChild("Base")
		local belt = base and base:FindFirstChild("LeftSideConveyor")
		if not belt or not belt:IsA("BasePart") then return origin end
		local c = pcf:PointToObjectSpace(belt.Position)
		-- the belt is yawed 90 degrees, so its depth along the plot's Z is Size.X
		cached = {
			z = c.Z + belt.Size.X * 0.5 - 0.8,   -- just inside the belt's far edge
			y = c.Y + belt.Size.Y * 0.5 + 2.5,   -- a short visible drop onto the belt
		}
		dropCache[plot] = cached
	end

	return pcf:PointToWorldSpace(Vector3.new(localOrigin.X, cached.y, cached.z))
end

-- Where a poop enters the world for a toilet standing at `origin`. Exposed so a
-- lucky block can arrive at the same place instead of inside the stall.
function PoopService.dropPoint(plot: Model, origin: Vector3): Vector3
	return dropPointFor(plot, origin)
end

function PoopService.drop(plot: Model, origin: Vector3, tier: number, mut: string, value: number)
	local bin = plot:FindFirstChild("WorldPoops")
	if not bin then return end

	-- cap the world population; oldest goes first so the plot never fills with parts
	local kids = bin:GetChildren()
	if #kids >= Config.MAX_WORLD_POOPS_PER_PLOT then
		table.sort(kids, function(a, b)
			return (a:GetAttribute("Born") or 0) < (b:GetAttribute("Born") or 0)
		end)
		for i = 1, #kids - Config.MAX_WORLD_POOPS_PER_PLOT + 1 do
			kids[i]:Destroy()
		end
	end

	local p = templateFor(tier, mut):Clone()
	p.Name = "Poop"
	p:SetAttribute("Value", value)
	-- what it counts as in the basket, which is not the same thing as what it is
	-- worth: see Config.poopCount
	p:SetAttribute("Count", Config.poopCount(tier))
	p:SetAttribute("Tier", tier)
	p:SetAttribute("Mutation", mut)
	p:SetAttribute("Born", os.clock())

	-- Drop it and let physics carry it: onto the belt, along to the collection area,
	-- where it piles and backs up on its own. Replaces the scripted waypoint route.
	local drop = dropPointFor(plot, origin)

	p:SetAttribute("Arrived", false)
	p.CFrame = CFrame.new(drop) * CFrame.Angles(
		math.random() * 6.28, math.random() * 6.28, math.random() * 6.28)
	p.Parent = bin
	p.AssemblyLinearVelocity = plot:GetPivot().LookVector * 2
	p.AssemblyAngularVelocity = Vector3.new(
		(math.random() - 0.5) * 6, (math.random() - 0.5) * 6, (math.random() - 0.5) * 6)
	return p
end

-- Poops used to blink out of existence on pickup. Fly them into the player instead,
-- the same magnetise read as the cash orbs. Marking Collected first stops runRoute
-- from overwriting the CFrame mid-flight.
local function flyIntoPlayer(part: BasePart, hrp: BasePart)
	part:SetAttribute("Collected", true)
	part.Anchored = false
	part.CanCollide = false
	part.CanTouch = false
	part.CanQuery = false

	-- The flight is a constraint, not a CFrame written every frame. An ANCHORED
	-- part's CFrame replicates at about 20Hz and the receiving client does not
	-- interpolate it, which is what made the magnetise stutter; a physics body is
	-- interpolated. Handing the collector network ownership goes further and
	-- simulates the whole flight on their own machine at their own frame rate.
	local from = Instance.new("Attachment")
	from.Parent = part
	local to = Instance.new("Attachment")
	to.Name = "PoopMagnet"
	to.Position = Vector3.new(0, 0.6, 0)
	to.Parent = hrp

	-- a small kick upward so it lifts off the floor before it snaps in
	part.AssemblyLinearVelocity = Vector3.new(0, 9, 0)
	part.AssemblyAngularVelocity = Vector3.new(
		(math.random() - 0.5) * 14, (math.random() - 0.5) * 14, (math.random() - 0.5) * 14)

	local align = Instance.new("AlignPosition")
	align.Attachment0 = from
	align.Attachment1 = to
	align.ApplyAtCenterOfMass = true
	align.MaxForce = 400000     -- a poop weighs well under a stud-cube; this is ample
	align.MaxVelocity = 600
	align.Responsiveness = 85   -- snap, not a swoop: it should be gone in a blink
	align.Parent = part

	local owner = Players:GetPlayerFromCharacter(hrp.Parent)
	if owner then pcall(function() part:SetNetworkOwner(owner) end) end

	-- short: the flight is over in a fraction of this, and a poop that somehow never
	-- reaches the player must not linger as a ghost
	Debris:AddItem(to, 0.35)
	Debris:AddItem(part, 0.35)
end

-- ── pickup ────────────────────────────────────────────────────────────────
-- `animate` flies each poop into the player. Auto Collect passes false: it should
-- quietly clear the heap, not hurl a stream of poop at you every second.
function PoopService.collect(player: Player, poops: { BasePart }, animate: boolean?)
	local profile = DataService.get(player)
	if not profile or #poops == 0 then return end

	local gained, counted, taken = 0, 0, {}
	for _, p in ipairs(poops) do
		-- already flying into someone; do not pay for it twice
		if not p:GetAttribute("Collected") then
			local v = p:GetAttribute("Value") or 0
			-- Count is written at drop time from the toilet's tier. Older poops already
			-- lying on a farm when this shipped have no attribute, so they count as one.
			local n = p:GetAttribute("Count") or 1
			gained += v
			counted += n
			table.insert(taken, { part = p, value = v, count = n })
		end
	end
	if #taken == 0 then return end

	profile.poops += gained
	profile.poopItems += counted
	local char = player.Character
	local hrp = char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
	local payload = table.create(#taken)
	for _, e in ipairs(taken) do
		table.insert(payload, { pos = e.part.Position, value = e.value, count = e.count })
		if animate and hrp then
			flyIntoPlayer(e.part, hrp)
		else
			e.part:Destroy()
		end
	end
	PickupEvent:FireClient(player, payload, profile.poops, profile.poopItems)
	DataService.push(player, { poops = profile.poops, poopItems = profile.poopItems })

	-- advances the "Collect N Poops" tutorial step
	local TutorialService = require(script.Parent.TutorialService)
	TutorialService.notify(player, "collect", counted)
end

-- "Arrived" means it has reached the collection area and settled, which is what
-- Auto Collect waits for.
--
-- Deliberately a position test, not a Touched on CollectionArea: the poops come to
-- rest about a stud ABOVE that part, because the area has a visible floor sitting
-- over its guide geometry, so they never actually touch it.
local areaCache: { [Model]: { cx: number, cz: number, hx: number, hz: number } } = {}

local function hasArrived(plot: Model, poop: BasePart): boolean
	if poop:GetAttribute("Arrived") then return true end
	local box = areaCache[plot]
	if not box then
		local base = plot:FindFirstChild("Base")
		local area = base and base:FindFirstChild("CollectionArea")
		if not area or not area:IsA("BasePart") then return false end
		local c = plot:GetPivot():PointToObjectSpace(area.Position)
		box = { cx = c.X, cz = c.Z, hx = area.Size.X * 0.5 + 1, hz = area.Size.Z * 0.5 + 1 }
		areaCache[plot] = box
	end
	local l = plot:GetPivot():PointToObjectSpace(poop.Position)
	if math.abs(l.X - box.cx) > box.hx or math.abs(l.Z - box.cz) > box.hz then
		return false
	end
	-- still tumbling in off the belt does not count as landed
	if poop.AssemblyLinearVelocity.Magnitude > 4 then return false end
	poop:SetAttribute("Arrived", true)
	return true
end

-- Every farm is ringed by invisible slabs under Plot*.Border. They are there to
-- stop poops rolling off the island, but they shipped as plain Default parts with
-- CanCollide off, so they did nothing at all. PoopWall is already registered to
-- collide with Poop and nothing else, so a player still walks straight through one.
--
-- The group is assigned FIRST and collision only enabled if that succeeded: a
-- barrier left in Default with CanCollide on would wall the player in.
local function armPoopBarriers(): number
	local plots = workspace:FindFirstChild("Plots")
	if not plots then return 0 end
	local armed = 0
	for _, plot in ipairs(plots:GetChildren()) do
		local border = plot:FindFirstChild("Border")
		if not border then continue end
		for _, part in ipairs(border:GetDescendants()) do
			if part:IsA("BasePart") and pcall(function() part.CollisionGroup = "PoopWall" end) then
				part.Anchored = true
				part.CanCollide = true
				part.CanQuery = false
				armed += 1
			end
		end
	end
	return armed
end

function PoopService.init()
	local armed = armPoopBarriers()
	if armed == 0 then
		warn("[PoopService] no Border barriers found -- poops can roll off the farms")
	end

	local acc = 0
	RunService.Heartbeat:Connect(function(dt)
		acc += dt
		if acc < 0.12 then return end
		acc = 0
		for _, player in ipairs(Players:GetPlayers()) do
			local plot = PlotService.plotFor(player)
			if not plot then continue end
			local char = player.Character
			local hrp = char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
			if not hrp then continue end
			local profile = DataService.get(player)
			if not profile then continue end

			local bin = plot:FindFirstChild("WorldPoops")
			if not bin then continue end

			-- The Settings screen ships an "Auto Poop Collect" switch that was wired to
			-- nothing: auto-collect only ever checked ownership. Owning it now arms the
			-- switch, and the switch decides whether it actually runs.
			local owns = PassService.has(player, "AutoFlush") or (profile.perks.AutoCollect or 0) > 0
			local auto = owns and profile.settings.AutoPoop == true
			local radius = Config.collectRadius(profile.upgrades.CollectRadius or 0)

			-- Walking up to a poop grabs it anywhere along the route, mid-belt included.
			-- Auto Collect instead waits until one has reached the heap and then just
			-- clears it, so the belt is still visibly doing its job.
			local near = {}
			for _, q in ipairs(bin:GetChildren()) do
				if q:IsA("BasePart") and not q:GetAttribute("Collected") then
					local reachable
					if auto then
						-- only once it has actually reached the collection area
						reachable = hasArrived(plot, q)
					else
						reachable = (q.Position - hrp.Position).Magnitude <= radius
					end
					if reachable then
						table.insert(near, q)
						if #near >= 25 then break end
					end
				end
			end
			if #near > 0 then
				PoopService.collect(player, near, not auto)
			end
		end
	end)
end

return PoopService
