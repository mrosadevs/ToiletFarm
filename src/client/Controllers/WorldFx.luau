--!strict
-- WorldFx — 3D feedback: springy walk-on pads, and the cash orbs that burst out,
-- bounce on the floor and then magnetise into you, XP-orb style.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local CollectionService = game:GetService("CollectionService")
local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Audio = require(script.Parent.Audio)

local player = Players.LocalPlayer

local WorldFx = {}

-- the cash icon already in the HUD
local CASH_ICON = "rbxassetid://116827946662700"

-- ── springy pads ─────────────────────────────────────────────────────────
-- Stepping on a pad squashes it down then springs back past its rest height,
-- rather than just dipping once.
local padBase: { [BasePart]: CFrame } = {}
local padAnim: { [BasePart]: boolean } = {}

local function springPad(plate: BasePart)
	if padAnim[plate] then return end
	padAnim[plate] = true
	local base = padBase[plate]
	if not base then
		base = plate.CFrame
		padBase[plate] = base
	end
	task.spawn(function()
		local t0 = os.clock()
		local DUR = 0.55
		while plate.Parent do
			local a = (os.clock() - t0) / DUR
			if a >= 1 then break end
			-- damped spring: dip hard, overshoot, settle
			local offset = -math.exp(-a * 6) * math.cos(a * 26) * 0.55
			local squash = 1 - math.exp(-a * 6) * math.cos(a * 26) * 0.18
			plate.CFrame = base * CFrame.new(0, offset, 0)
			plate.Size = Vector3.new(plate.Size.X, plate.Size.Y, plate.Size.Z)
			task.wait()
		end
		if plate.Parent then plate.CFrame = base end
		padAnim[plate] = nil
	end)
end

function WorldFx.bindPads()
	local function bind(zone: BasePart)
		local pad = zone.Parent
		if not pad then return end
		-- Each pad is a flat base "Plate" plus a raised "Part" that is the button
		-- face. Pressing the Plate looks wrong: the base is what should stay put.
		local plate = nil
		local bestVol = -1
		for _, c in ipairs(pad:GetChildren()) do
			if c:IsA("BasePart") and c.Name ~= "Plate" and c.Name ~= "TouchZone" and c.Name ~= "TextAnchor" then
				local v = c.Size.X * c.Size.Y * c.Size.Z
				if v > bestVol then bestVol = v; plate = c end
			end
		end
		plate = plate or pad:FindFirstChild("Plate")
		if not plate or not plate:IsA("BasePart") then return end
		zone.Touched:Connect(function(hit)
			local char = player.Character
			if not char or not hit:IsDescendantOf(char) then return end
			springPad(plate)
		end)
	end
	for _, z in ipairs(CollectionService:GetTagged("PadTouch")) do bind(z) end
	CollectionService:GetInstanceAddedSignal("PadTouch"):Connect(bind)
end

-- ── cash orbs ───────────────────────────────────────────────────────────
local function makeOrb(pos: Vector3): BasePart
	local p = Instance.new("Part")
	p.Size = Vector3.new(1.1, 1.1, 0.2)
	p.Transparency = 1
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CFrame = CFrame.new(pos)
	local bb = Instance.new("BillboardGui")
	bb.Size = UDim2.fromScale(3, 3)
	-- draw over the character: big accessories otherwise swallow the whole burst
	bb.AlwaysOnTop = true
	local img = Instance.new("ImageLabel")
	img.Size = UDim2.fromScale(1, 1)
	img.BackgroundTransparency = 1
	img.Image = CASH_ICON
	img.Parent = bb
	bb.Parent = p
	p.Parent = workspace
	return p
end

-- burst out, arc to the floor, sit a beat, then fly into the player
function WorldFx.cashBurst(origin: Vector3?, count: number?)
	local char = player.Character
	local hrp = char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not hrp then return end
	local from = origin or hrp.Position
	local n = math.clamp(count or 14, 6, 26)

	Audio.play("MoneyCollect")

	for i = 1, n do
		task.spawn(function()
			local orb = makeOrb(from + Vector3.new(0, 3, 0))
			-- scatter wide enough to clear the player's own model
			local ang = math.random() * math.pi * 2
			local dist = 5 + math.random() * 6
			local landing = from + Vector3.new(math.cos(ang) * dist, 0, math.sin(ang) * dist)

			-- ground the landing point
			local params = RaycastParams.new()
			params.FilterType = Enum.RaycastFilterType.Exclude
			params.FilterDescendantsInstances = { char, orb }
			local hit = workspace:Raycast(landing + Vector3.new(0, 8, 0), Vector3.new(0, -40, 0), params)
			local groundY = hit and hit.Position.Y + 0.8 or from.Y
			local to = Vector3.new(landing.X, groundY, landing.Z)

			-- 1. pop out and land
			local start = orb.Position
			local t0 = os.clock()
			local DUR = 0.35 + math.random() * 0.15
			while orb.Parent do
				local a = (os.clock() - t0) / DUR
				if a >= 1 then break end
				local pos = start:Lerp(to, a) + Vector3.new(0, math.sin(a * math.pi) * 4.5, 0)
				orb.CFrame = CFrame.new(pos)
				task.wait()
			end

			-- 2. short rest, staggered so they don't all leave at once
			task.wait(0.12 + i * 0.012 + math.random() * 0.1)

			-- 3. magnetise into the player, accelerating
			local t1 = os.clock()
			local MAG = 0.45
			local fromPos = orb.Position
			while orb.Parent do
				local a = (os.clock() - t1) / MAG
				if a >= 1 then break end
				local target = hrp.Position
				if not hrp.Parent then break end
				-- ease-in so it snaps home at the end
				orb.CFrame = CFrame.new(fromPos:Lerp(target, a * a))
				task.wait()
			end
			-- a plop per orb as it lands in you, same pickup cue as poop
			Audio.play("PoopPlop", { volume = 0.35, speed = 1.15 + (math.random() - 0.5) * 0.25 })
			orb:Destroy()
		end)
	end
end

-- ── plot ambience ─────────────────────────────────────────────────
-- A flush when a toilet actually drops, and the Lucky Block chime when one
-- appears on the plot. Both are driven off the world rather than a remote, so
-- they stay in sync with what the player can see and respect Mute Toilets.
local FLUSH_THROTTLE = 0.16

local function ownedPlot(): Model?
	local plots = workspace:FindFirstChild("Plots")
	if not plots then return nil end
	for _, plot in ipairs(plots:GetChildren()) do
		if plot:GetAttribute("OwnerUserId") == player.UserId then return plot :: Model end
	end
	return nil
end

function WorldFx.bindPlotSounds()
	task.spawn(function()
		local plot: Model? = nil
		-- the plot is claimed a moment after join, so wait for it
		for _ = 1, 120 do
			plot = ownedPlot()
			if plot then break end
			task.wait(0.25)
		end
		if not plot then return end

		local lastFlush = 0
		local bin = plot:WaitForChild("WorldPoops", 10)
		if bin then
			bin.ChildAdded:Connect(function(poop)
				if not poop:IsA("BasePart") then return end
				-- a full farm drops dozens a second; one flush per beat is plenty
				local now = os.clock()
				if now - lastFlush < FLUSH_THROTTLE then return end
				lastFlush = now
				-- quiet: this fires constantly on a full farm and drowns everything else
				Audio.play("Flush", { volume = 0.25, speed = 1 + (math.random() - 0.5) * 0.2 })
			end)
		end

		plot.ChildAdded:Connect(function(child)
			if child.Name == "LuckyBlock" then
				Audio.play("LuckySpawn")
			end
		end)
	end)
end

-- ── silence Roblox's own character sounds ───────────────────────────────────
-- These are created by the stock RbxCharacterSounds LocalScript, so they only ever
-- exist on the client — a server-side mute never sees them. We play our own
-- FootstepL/R, so drop the vanilla layer entirely.
local STOCK_SOUNDS = {
	Running = true, Landing = true, FreeFalling = true, Jumping = true,
	GettingUp = true, Climbing = true, Swimming = true, Splash = true,
}

local function muteStockSounds(character: Model)
	local hrp = character:WaitForChild("HumanoidRootPart", 10)
	if not hrp then return end
	local function handle(child: Instance)
		if child:IsA("Sound") and STOCK_SOUNDS[child.Name] then
			child.Volume = 0
			-- RbxCharacterSounds re-applies volume as it plays, so pin it
			child:GetPropertyChangedSignal("Volume"):Connect(function()
				if child.Volume ~= 0 then child.Volume = 0 end
			end)
		end
	end
	for _, c in ipairs(hrp:GetChildren()) do handle(c) end
	hrp.ChildAdded:Connect(handle)
end

function WorldFx.muteVanillaSounds()
	local function watch(other: Player)
		if other.Character then task.spawn(muteStockSounds, other.Character) end
		other.CharacterAdded:Connect(function(char) task.spawn(muteStockSounds, char) end)
	end
	for _, other in ipairs(Players:GetPlayers()) do watch(other) end
	Players.PlayerAdded:Connect(watch)
end

-- ── footsteps ───────────────────────────────────────────────────────────
function WorldFx.bindFootsteps()
	local function attach(char: Model)
		local humanoid = char:WaitForChild("Humanoid", 5) :: Humanoid?
		if not humanoid then return end
		local left = true
		local accum = 0
		local conn
		conn = RunService.Heartbeat:Connect(function(dt)
			if not humanoid.Parent then conn:Disconnect() return end
			if humanoid.MoveDirection.Magnitude < 0.1 then accum = 0.35 return end
			if humanoid.FloorMaterial == Enum.Material.Air then return end
			accum += dt * (humanoid.WalkSpeed / 16)
			if accum >= 0.42 then
				accum = 0
				Audio.play(left and "FootstepL" or "FootstepR", { volume = 0.35 })
				left = not left
			end
		end)
	end
	if player.Character then attach(player.Character) end
	player.CharacterAdded:Connect(attach)
end

return WorldFx
