--!strict
-- WorldFx — 3D feedback: springy walk-on pads, and the cash orbs that burst out,
-- bounce on the floor and then magnetise into you, XP-orb style.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local CollectionService = game:GetService("CollectionService")
local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Debris = game:GetService("Debris")

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

-- ── Flush Multiplier hologram ───────────────────────────────────────────────
-- The multiplier is server-wide, so it belongs in the shared space rather than on
-- one player's screen: a hologram floating over the leaderboards in the middle of
-- the hub, where everyone is looking at the same number.
--
-- Built per client rather than replicated from the server. It is pure decoration,
-- and the countdown can then tick smoothly off the FlushMeter payload the client
-- already receives, instead of the server pushing a new string ten times a second.

local Config = require(ReplicatedStorage:WaitForChild("Shared").ToiletConfig)
local Net = require(ReplicatedStorage:WaitForChild("Shared").Net)

-- The Flush Multiplier hangs over the hub leaderboards, where it is one shared
-- number everyone reads rather than a private copy on each player's screen. It
-- spent one revision on the HUD to be visible from a farm; that is not what it is
-- for, so it is back in the world and simply cannot be read from 200 studs away --
-- a billboard shrinks with distance whichever unit it is sized in.
local function hologramAnchor(): CFrame
	local hub = workspace:FindFirstChild("Hub")
	-- centre it on the leaderboard cluster and float it clear of their tops
	if hub then
		local sum, count, highest = Vector3.zero, 0, -math.huge
		for _, m in ipairs(hub:GetChildren()) do
			if m:IsA("Model") and m.Name:match("^Leaderboard") then
				local cf, size = m:GetBoundingBox()
				sum += cf.Position
				highest = math.max(highest, cf.Position.Y + size.Y * 0.5)
				count += 1
			end
		end
		if count > 0 then
			local centre = sum / count
			-- Threaded between two things: the board is 11 studs tall and centred here,
			-- so +6 puts its bottom edge half a stud ABOVE the leaderboard tops -- any
			-- lower and whichever board is nearest the camera cuts across the bar --
			-- while staying low enough that the HUD's own Home button does not clip
			-- the title from the hub floor, which is where it is meant to be read.
			return CFrame.new(centre.X, highest + 16, centre.Z)
		end
	end
	local centre = workspace:FindFirstChild("Center")
	if centre and centre:IsA("Model") then
		local cf, size = centre:GetBoundingBox()
		return CFrame.new(cf.Position.X, cf.Position.Y + size.Y * 0.5 + 32, cf.Position.Z)
	end
	return CFrame.new(0, 48, 0)
end

local function meterColour(mult: number): Color3
	if mult >= 2 then return Color3.fromRGB(255, 215, 60) end
	if mult >= 1.5 then return Color3.fromRGB(120, 255, 140) end
	if mult >= 1.25 then return Color3.fromRGB(150, 230, 255) end
	if mult >= 1 then return Color3.fromRGB(235, 235, 240) end
	return Color3.fromRGB(255, 120, 120)
end

function WorldFx.buildFlushHologram()
	local anchor = Instance.new("Part")
	anchor.Name = "FlushHologramAnchor"
	anchor.Size = Vector3.new(1, 1, 1)
	anchor.Transparency = 1
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.CanQuery = false
	anchor.CanTouch = false
	anchor.CastShadow = false
	anchor.CFrame = hologramAnchor()
	anchor.Parent = workspace

	local board = Instance.new("BillboardGui")
	board.Name = "FlushHologram"
	-- Sized in STUDS, not pixels: an offset-sized billboard is enormous up close and
	-- swallowed the middle of the screen. Wide and shallow, matching the proportions
	-- of the reference game's Egg Multiplier -- a title line over a long thin scale.
	board.Size = UDim2.fromScale(92, 22)
	board.StudsOffsetWorldSpace = Vector3.new(0, 0, 0)
	-- No practical range limit. At 170 the widget switched off the moment the camera
	-- got further away than that -- which is most of the hub once you zoom out, and
	-- is why it seemed to need "a certain angle or zoom" to appear. Occlusion is the
	-- smaller half of that complaint: measured over 144 viewpoints around the hub,
	-- only about one in ten is blocked, essentially all of them standing directly
	-- behind a leaderboard.
	--
	-- AlwaysOnTop would clear that last tenth and CANNOT be used: it renders this
	-- billboard as nothing at all. Verified three ways -- stud-sized, pixel-sized,
	-- and with the anchor part made barely-visible in case a fully transparent
	-- adornee was being culled out of the always-on-top pass. All three drew nothing.
	board.MaxDistance = 1200
	board.LightInfluence = 0
	-- Must stay false. A BillboardGui sized in SCALE renders NOTHING at all with
	-- AlwaysOnTop on -- that mode wants an Offset size -- so the whole widget simply
	-- disappears. Occlusion by the leaderboards is handled by sitting above them.
	board.AlwaysOnTop = false
	board.Parent = anchor

	-- Laid out after the reference game's Egg Multiplier: one title line carrying the
	-- value, and under it a long thin scale coloured across the whole range of rolls
	-- with a pointer marking where this one landed. No panel behind it -- the design
	-- reads as light in the air, and a black stroke carries it against the sky.
	local panel = Instance.new("Frame")
	panel.Size = UDim2.fromScale(1, 1)
	panel.BackgroundTransparency = 1
	panel.Parent = board

	-- everything below is laid out in SCALE so it follows the stud-sized billboard
	local title = Instance.new("TextLabel")
	title.Name = "Title"
	-- Sits low in the billboard on purpose. The board has to hang high enough that
	-- the bar clears the leaderboard tops, and at that height a title pinned to the
	-- top edge lands behind the HUD's Home button. Dropping the content down the
	-- board buys that clearance without shrinking the text.
	title.Size = UDim2.fromScale(1, 0.44)
	title.Position = UDim2.fromScale(0, 0.16)
	title.BackgroundTransparency = 1
	title.Font = Enum.Font.FredokaOne
	title.TextScaled = true
	-- the peach the reference uses, not a cyan that fights the sky
	title.TextColor3 = Color3.fromRGB(255, 205, 165)
	title.Text = "Flush Multiplier: 1x"
	local tls = Instance.new("UIStroke")
	tls.Thickness = 4
	tls.Color = Color3.new(0, 0, 0)
	tls.Parent = title
	title.Parent = panel

	local track = Instance.new("Frame")
	track.Name = "Track"
	track.AnchorPoint = Vector2.new(0.5, 0)
	track.Position = UDim2.fromScale(0.5, 0.64)
	track.Size = UDim2.fromScale(0.9, 0.28)
	track.BackgroundColor3 = Color3.new(1, 1, 1)
	track.BorderSizePixel = 0
	local tc = Instance.new("UICorner"); tc.CornerRadius = UDim.new(1, 0); tc.Parent = track
	local ts = Instance.new("UIStroke"); ts.Thickness = 3; ts.Color = Color3.new(0, 0, 0); ts.Parent = track
	-- The gradient is the SCALE, not a fill: it spans every multiplier the table can
	-- roll, worst on the left to best on the right, so the pointer's position alone
	-- says whether this roll was good.
	local grad = Instance.new("UIGradient")
	grad.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0.0, Color3.fromRGB(235, 90, 80)),
		ColorSequenceKeypoint.new(0.4, Color3.fromRGB(245, 165, 50)),
		ColorSequenceKeypoint.new(0.7, Color3.fromRGB(245, 225, 70)),
		ColorSequenceKeypoint.new(1.0, Color3.fromRGB(85, 220, 90)),
	})
	grad.Parent = track
	track.Parent = panel

	-- the part of the scale beyond where this roll landed, dimmed back
	local shade = Instance.new("Frame")
	shade.Name = "Shade"
	shade.AnchorPoint = Vector2.new(1, 0)
	shade.Position = UDim2.fromScale(1, 0)
	shade.Size = UDim2.fromScale(0.5, 1)
	shade.BackgroundColor3 = Color3.fromRGB(20, 20, 25)
	shade.BackgroundTransparency = 0.55
	shade.BorderSizePixel = 0
	shade.ZIndex = 2
	local sc = Instance.new("UICorner"); sc.CornerRadius = UDim.new(1, 0); sc.Parent = shade
	shade.Parent = track

	local timer = Instance.new("TextLabel")
	timer.Name = "Timer"
	timer.Size = UDim2.fromScale(1, 1)
	timer.BackgroundTransparency = 1
	timer.Font = Enum.Font.FredokaOne
	timer.TextScaled = true
	timer.TextColor3 = Color3.new(1, 1, 1)
	timer.Text = ""
	timer.ZIndex = 4
	local tp = Instance.new("UIPadding")
	tp.PaddingTop = UDim.new(0.14, 0); tp.PaddingBottom = UDim.new(0.14, 0)
	tp.Parent = timer
	local tms = Instance.new("UIStroke"); tms.Thickness = 3; tms.Color = Color3.new(0, 0, 0); tms.Parent = timer
	timer.Parent = track

	-- the marker under the bar, pointing up at where this roll landed
	local pointer = Instance.new("TextLabel")
	pointer.Name = "Pointer"
	pointer.AnchorPoint = Vector2.new(0.5, 0)
	pointer.Size = UDim2.fromScale(0.07, 0.15)
	pointer.Position = UDim2.fromScale(0.5, 0.92)
	pointer.BackgroundTransparency = 1
	pointer.Font = Enum.Font.FredokaOne
	pointer.TextScaled = true
	pointer.TextColor3 = Color3.new(0, 0, 0)
	pointer.Text = "\u{25B2}"
	pointer.ZIndex = 5
	pointer.Parent = panel

	-- where a given multiplier sits along the scale, 0 at the worst roll the table
	-- can produce and 1 at the best
	local lowest, highest = math.huge, -math.huge
	for _, e in ipairs(Config.FLUSH_METER.table) do
		lowest = math.min(lowest, e.mult)
		highest = math.max(highest, e.mult)
	end
	local function positionOf(mult: number): number
		if highest <= lowest then return 0.5 end
		return math.clamp((mult - lowest) / (highest - lowest), 0, 1)
	end

	local function show(mult: number)
		title.Text = ("Flush Multiplier: %sx"):format(mult)
		title.TextColor3 = meterColour(mult)
		local at = positionOf(mult)
		-- the pointer rides the track, so its span has to match the track's, not the
		-- whole board's: the track is 0.9 wide and centred.
		pointer.Position = UDim2.fromScale(0.05 + at * 0.9, 0.92)
		shade.Size = UDim2.fromScale(1 - at, 1)
	end
	show(1)

	local state = { mult = 1, nextRollAt = 0, period = Config.FLUSH_METER.period }
	Net.event(Net.NAMES.FlushMeter).OnClientEvent:Connect(function(payload)
		state = payload
		show(payload.mult)
	end)

	-- gentle bob, so it reads as a hologram rather than a decal in the sky
	local baseY = anchor.Position.Y
	task.spawn(function()
		while anchor.Parent do
			task.wait(0.1)
			local left = state.nextRollAt - workspace:GetServerTimeNow()
			timer.Text = left > 0 and ("Updating in %ds"):format(math.ceil(left)) or "Updating..."
			anchor.CFrame = CFrame.new(
				anchor.Position.X,
				baseY + math.sin(workspace:GetServerTimeNow() * 1.1) * 0.7,
				anchor.Position.Z
			)
		end
	end)

	return anchor
end

-- ── one-shot particle bursts ─────────────────────────────────────────────
-- Built and emitted HERE rather than on the server. :Emit() replicates as an event
-- to clients that already have the part, and the server was emitting in the same
-- frame it parented the carrier, so the burst consistently landed before the part
-- arrived and nothing was ever drawn. Locally there is no replication in the path:
-- the template is already in ReplicatedStorage, so build, emit and clean up.
function WorldFx.bindVfx()
	local assets = ReplicatedStorage:WaitForChild("VfxAssets", 30)
	if not assets then
		warn("[WorldFx] VfxAssets never appeared -- no effects will play")
		return
	end

	Net.event(Net.NAMES.PlayVfx).OnClientEvent:Connect(function(key, position, burst)
		if typeof(key) ~= "string" or typeof(position) ~= "Vector3" then return end
		local template = assets:FindFirstChild(key)
		if not template or not template:IsA("BasePart") then return end

		local part = template:Clone()
		part.CFrame = CFrame.new(position)
		part.Parent = workspace

		local n = math.clamp(tonumber(burst) or 18, 1, 200)
		local longest = 1
		for _, d in ipairs(part:GetDescendants()) do
			if d:IsA("ParticleEmitter") then
				d.Enabled = false
				d:Emit(n)
				longest = math.max(longest, d.Lifetime.Max)
			end
		end
		Debris:AddItem(part, longest + 0.5)
	end)
end

return WorldFx
