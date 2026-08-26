--!strict
-- Freecam — a detached, damped camera for filming. Shift+F to fly, Shift+F to land.
--
-- Shift+F rather than the Shift+P a flycam usually gets, because Studio injects its
-- OWN freecam into every playtest on Shift+P. Sharing the key means both wake up at
-- once, they take the camera off each other, and the result looks broken in exactly
-- the place the game is tested. That injected one is Studio-only — it is nowhere in
-- StarterGui, so a published client has no freecam at all without this.
--
-- This is a CAMERA and nothing else. The camera has always belonged to the client,
-- and the server owns every number that matters, so flying one around cannot reach
-- anything — which is why this can ship switched on without opening a hole. ALLOW
-- below is a convenience, not a security boundary: a client-side check is bypassable
-- by anyone who cares to, and there is nothing behind it worth the bother.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local StarterGui = game:GetService("StarterGui")
local TweenService = game:GetService("TweenService")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local Freecam = {}

-- Who may fly. EMPTY MEANS EVERYONE, which is the default so the person filming
-- needs nothing set up on their account. To lock it down, list UserIds:
--     local ALLOW: { number } = { 1234567, 7654321 }
local ALLOW: { number } = {}

-- ── feel ──────────────────────────────────────────────────────────────────
local SPEED_DEFAULT = 55 -- studs/second
local SPEED_MIN, SPEED_MAX = 2, 900
local SPEED_STEP = 1.18 -- one wheel notch, multiplicative
local BOOST, PRECISE = 3.5, 0.2

-- Time constants for the smoothing, in seconds: roughly how long a change takes to
-- arrive. This is the whole difference between footage and a jerky flycam — raw
-- input written straight onto the CFrame reads as a snap on every keypress, and no
-- amount of editing rescues it afterwards.
local MOVE_TAU = 0.17
local LOOK_TAU = 0.055
local FOV_TAU = 0.12
local ROLL_TAU = 0.18

local LOOK_SENS = 0.0032 -- radians per pixel of mouse travel
local PAD_LOOK = 2.8 -- radians/second at full stick
local PAD_DEADZONE = 0.14
local PITCH_LIMIT = math.rad(89) -- stop short, so it can never gimbal over the top
local ROLL_RATE = math.rad(50) -- per second, while Z or X is held
local FOV_RATE = 30 -- degrees/second, while [ or ] is held
local FOV_MIN, FOV_MAX = 5, 120

-- ── state ─────────────────────────────────────────────────────────────────
local active = false
local allowed: boolean? = nil

local pos = Vector3.zero
local vel = Vector3.zero
local yaw, pitch, roll = 0, 0, 0
local wantYaw, wantPitch, wantRoll = 0, 0, 0
local speed = SPEED_DEFAULT
local fov, wantFov = 70, 70

local uiHidden = false
local charHidden = false
-- Entering hides the GAME's UI immediately, because a clean frame is the whole
-- point. The freecam's own legend is deliberately not part of that — it fades by
-- itself, and H is what takes it away early along with everything else.
local overlayOn = true

type Saved = {
	cameraType: Enum.CameraType,
	cameraSubject: Instance?,
	fov: number,
	mouseBehavior: Enum.MouseBehavior,
	mouseIcon: boolean,
	walkSpeed: number?,
	jumpPower: number?,
	nameDisplay: Enum.HumanoidDisplayDistanceType?,
	healthDisplay: Enum.HumanoidHealthDisplayType?,
}

-- everything we have to put back on the way out
local saved: Saved? = nil
local hiddenGuis: { ScreenGui } = {}
local coreState: { [Enum.CoreGuiType]: boolean } = {}
local controls: any = nil

-- ── the legend and the readout ────────────────────────────────────────────
-- Both fade on their own. A trailer camera whose own HUD is stuck in the shot is
-- worse than no HUD at all, so nothing here stays up longer than it is useful.
local gui: ScreenGui? = nil
local legend: TextLabel? = nil
local readout: TextLabel? = nil
local legendToken, readoutToken = 0, 0

local LEGEND = table.concat({
	"FREECAM        Shift+F to exit",
	"WASD fly  ·  Q/E down/up  ·  Shift fast  ·  Ctrl slow",
	"Wheel speed  ·  [ ] zoom  ·  Z/X roll  ·  Backslash resets",
	"H hides the UI  ·  T hides your character",
}, "\n")

local function mkLabel(name: string): TextLabel
	local l = Instance.new("TextLabel")
	l.Name = name
	l.AnchorPoint = Vector2.new(0, 1)
	l.BackgroundTransparency = 1
	l.Font = Enum.Font.GothamMedium
	l.TextColor3 = Color3.new(1, 1, 1)
	l.TextXAlignment = Enum.TextXAlignment.Left
	l.TextYAlignment = Enum.TextYAlignment.Bottom
	l.LineHeight = 1.25
	l.Text = ""
	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 2
	stroke.Color = Color3.new(0, 0, 0)
	stroke.Transparency = 0.35
	stroke.Parent = l
	return l
end

local function buildGui()
	if gui then return end
	local g = Instance.new("ScreenGui")
	g.Name = "FreecamGui"
	g.ResetOnSpawn = false
	g.IgnoreGuiInset = true
	g.DisplayOrder = 10000
	g.Enabled = false
	g.Parent = playerGui

	local lg = mkLabel("Legend")
	lg.Parent = g
	legend = lg

	local rd = mkLabel("Readout")
	rd.TextTransparency = 1
	rd.Parent = g
	readout = rd

	gui = g
end

-- Sized off the viewport rather than fixed pixels. 15px is fine on a laptop and
-- unreadable on the 3100-wide screen this is most likely to be filmed on, and the
-- person reading it is reading it once.
local function layoutGui()
	local camera = workspace.CurrentCamera
	local h = camera and camera.ViewportSize.Y or 1080
	local px = math.clamp(math.round(h * 0.017), 14, 34)
	local pad = math.round(px * 1.6)
	if legend then
		local l = legend :: TextLabel
		l.TextSize = px
		l.Size = UDim2.fromOffset(px * 46, px * 7)
		l.Position = UDim2.new(0, pad, 1, -pad)
	end
	if readout then
		local r = readout :: TextLabel
		r.TextSize = math.round(px * 1.15)
		r.Size = UDim2.fromOffset(px * 30, px * 1.8)
		r.Position = UDim2.new(0, pad, 1, -pad - px * 7.6)
	end
end

local function fade(l: TextLabel?, token: number, isLegend: boolean, hold: number)
	if not l then return end
	local stroke = l:FindFirstChildOfClass("UIStroke")
	l.TextTransparency = 0
	if stroke then stroke.Transparency = 0.35 end
	task.delay(hold, function()
		local live = if isLegend then legendToken else readoutToken
		if live ~= token or not l.Parent then return end
		local info = TweenInfo.new(0.6, Enum.EasingStyle.Quad)
		TweenService:Create(l, info, { TextTransparency = 1 }):Play()
		if stroke then TweenService:Create(stroke, info, { Transparency = 1 }):Play() end
	end)
end

local function showLegend()
	legendToken += 1
	if legend then legend.Text = LEGEND end
	fade(legend, legendToken, true, 7)
end

-- called whenever a dial moves, so the number is on screen only while you are
-- actually turning it
local function showReadout()
	readoutToken += 1
	if readout then
		readout.Text = ("%d studs/s   ·   %d° FOV"):format(math.round(speed), math.round(wantFov))
	end
	fade(readout, readoutToken, false, 1.4)
end

-- ── hiding things ─────────────────────────────────────────────────────────
local function setUiHidden(hide: boolean)
	uiHidden = hide
	if hide then
		table.clear(hiddenGuis)
		for _, g in ipairs(playerGui:GetChildren()) do
			if g:IsA("ScreenGui") and g ~= gui and g.Enabled then
				g.Enabled = false
				table.insert(hiddenGuis, g)
			end
		end
		for _, t in ipairs(Enum.CoreGuiType:GetEnumItems()) do
			if t ~= Enum.CoreGuiType.All then coreState[t] = StarterGui:GetCoreGuiEnabled(t) end
		end
		StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.All, false)
		pcall(function()
			StarterGui:SetCore("TopbarEnabled", false)
		end)
	else
		-- only the ones WE turned off, so a panel the player had closed stays closed
		for _, g in ipairs(hiddenGuis) do
			if g.Parent then g.Enabled = true end
		end
		table.clear(hiddenGuis)
		for t, was in pairs(coreState) do
			pcall(function()
				StarterGui:SetCoreGuiEnabled(t, was)
			end)
		end
		table.clear(coreState)
		pcall(function()
			StarterGui:SetCore("TopbarEnabled", true)
		end)
	end
end

local function refreshOverlay()
	if gui then gui.Enabled = active and overlayOn end
end

-- LocalTransparencyModifier is reapplied every frame rather than written once: the
-- engine rewrites it on the LOCAL character as the camera moves, so a single write
-- survives about one frame.
local function applyCharHidden()
	local char = player.Character
	if not char then return end
	for _, d in ipairs(char:GetDescendants()) do
		if d:IsA("BasePart") or d:IsA("Decal") or d:IsA("Texture") then d.LocalTransparencyModifier = 1 end
	end
end

local function restoreChar()
	local char = player.Character
	if not char then return end
	for _, d in ipairs(char:GetDescendants()) do
		if d:IsA("BasePart") or d:IsA("Decal") or d:IsA("Texture") then d.LocalTransparencyModifier = 0 end
	end
end

-- ── freezing the character ────────────────────────────────────────────────
-- Two belts. Disabling the control module is the clean way, but it is a CoreScript
-- we do not own; zeroing the humanoid means that even if it is missing, the avatar
-- cannot be walked off camera by the very keys we are flying with.
local function freeze(char: Model?)
	if controls then pcall(function()
		controls:Disable()
	end) end
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	local s = saved
	if hum and s then
		s.walkSpeed = s.walkSpeed or hum.WalkSpeed
		s.jumpPower = s.jumpPower or hum.JumpPower
		s.nameDisplay = s.nameDisplay or hum.DisplayDistanceType
		s.healthDisplay = s.healthDisplay or hum.HealthDisplayType
		hum.WalkSpeed = 0
		hum.JumpPower = 0
		-- your own nameplate otherwise hangs in the middle of every shot
		hum.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
		hum.HealthDisplayType = Enum.HumanoidHealthDisplayType.AlwaysOff
	end
end

local function thaw()
	if controls then pcall(function()
		controls:Enable()
	end) end
	local char = player.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	local s = saved
	if hum and s then
		if s.walkSpeed then hum.WalkSpeed = s.walkSpeed end
		if s.jumpPower then hum.JumpPower = s.jumpPower end
		if s.nameDisplay then hum.DisplayDistanceType = s.nameDisplay end
		if s.healthDisplay then hum.HealthDisplayType = s.healthDisplay end
	end
end

-- ── input helpers ─────────────────────────────────────────────────────────
local function down(key: Enum.KeyCode): number
	return UserInputService:IsKeyDown(key) and 1 or 0
end

local function deadzone(v: number): number
	if math.abs(v) < PAD_DEADZONE then return 0 end
	-- rescaled from the edge of the deadzone rather than jumping straight to 0.14,
	-- and squared, which is what stops a stick feeling notchy at low deflection
	local s = (math.abs(v) - PAD_DEADZONE) / (1 - PAD_DEADZONE)
	return math.sign(v) * s * s
end

local function padState(): (Vector2, Vector2, number)
	if not UserInputService.GamepadEnabled then return Vector2.zero, Vector2.zero, 0 end
	local ok, inputs = pcall(function()
		return UserInputService:GetGamepadState(Enum.UserInputType.Gamepad1)
	end)
	if not ok or not inputs then return Vector2.zero, Vector2.zero, 0 end
	local move, look, lift = Vector2.zero, Vector2.zero, 0
	for _, i in ipairs(inputs) do
		if i.KeyCode == Enum.KeyCode.Thumbstick1 then
			move = Vector2.new(deadzone(i.Position.X), deadzone(i.Position.Y))
		elseif i.KeyCode == Enum.KeyCode.Thumbstick2 then
			look = Vector2.new(deadzone(i.Position.X), deadzone(i.Position.Y))
		elseif i.KeyCode == Enum.KeyCode.ButtonR2 then
			lift += i.Position.Z
		elseif i.KeyCode == Enum.KeyCode.ButtonL2 then
			lift -= i.Position.Z
		end
	end
	return move, look, lift
end

-- ── the step ──────────────────────────────────────────────────────────────
local function step(dt: number)
	local camera = workspace.CurrentCamera
	if not camera then return end
	dt = math.min(dt, 1 / 20) -- a hitch must not fling the camera across the map

	local padMove, padLook, padLift = padState()

	-- look
	wantYaw -= padLook.X * PAD_LOOK * dt
	wantPitch = math.clamp(wantPitch + padLook.Y * PAD_LOOK * dt, -PITCH_LIMIT, PITCH_LIMIT)
	wantRoll += (down(Enum.KeyCode.X) - down(Enum.KeyCode.Z)) * ROLL_RATE * dt

	-- zoom
	local fovIn = down(Enum.KeyCode.RightBracket) - down(Enum.KeyCode.LeftBracket)
	if fovIn ~= 0 then
		wantFov = math.clamp(wantFov - fovIn * FOV_RATE * dt, FOV_MIN, FOV_MAX)
		showReadout()
	end

	-- Exponential smoothing, which is frame-rate independent — a flat lerp factor
	-- makes the camera feel different on a 60Hz monitor and a 144Hz one.
	local aLook = 1 - math.exp(-dt / LOOK_TAU)
	yaw += (wantYaw - yaw) * aLook
	pitch += (wantPitch - pitch) * aLook
	roll += (wantRoll - roll) * (1 - math.exp(-dt / ROLL_TAU))
	fov += (wantFov - fov) * (1 - math.exp(-dt / FOV_TAU))

	local rot = CFrame.fromEulerAnglesYXZ(pitch, yaw, roll)

	-- Move: WASD is camera-relative so W flies where you are looking, but Q/E stay
	-- on world up. Camera-relative lift drifts sideways the moment you are pitched,
	-- which makes a straight rise up the side of a farm impossible to hold.
	local flat = Vector3.new(
		down(Enum.KeyCode.D) - down(Enum.KeyCode.A) + padMove.X,
		0,
		down(Enum.KeyCode.S) - down(Enum.KeyCode.W) - padMove.Y
	)
	local lift = down(Enum.KeyCode.E) - down(Enum.KeyCode.Q) + down(Enum.KeyCode.Space) + padLift
	local dir = rot:VectorToWorldSpace(flat) + Vector3.yAxis * lift
	if dir.Magnitude > 1 then dir = dir.Unit end

	local mult = 1
	if
		UserInputService:IsKeyDown(Enum.KeyCode.LeftShift)
		or UserInputService:IsKeyDown(Enum.KeyCode.RightShift)
	then
		mult *= BOOST
	end
	if
		UserInputService:IsKeyDown(Enum.KeyCode.LeftControl)
		or UserInputService:IsKeyDown(Enum.KeyCode.RightControl)
	then
		mult *= PRECISE
	end

	vel = vel:Lerp(dir * speed * mult, 1 - math.exp(-dt / MOVE_TAU))
	pos += vel * dt

	camera.CFrame = CFrame.new(pos) * rot
	camera.FieldOfView = fov
	camera.Focus = camera.CFrame * CFrame.new(0, 0, -20)

	if charHidden then applyCharHidden() end
end

-- ── entering and leaving ──────────────────────────────────────────────────
function Freecam.enter()
	if active then return end
	local camera = workspace.CurrentCamera
	if not camera then return end
	active = true

	saved = {
		cameraType = camera.CameraType,
		cameraSubject = camera.CameraSubject,
		fov = camera.FieldOfView,
		mouseBehavior = UserInputService.MouseBehavior,
		mouseIcon = UserInputService.MouseIconEnabled,
	}

	-- Start exactly where the player was already looking, so entering is a handover
	-- rather than a cut to somewhere else entirely.
	local cf = camera.CFrame
	pos = cf.Position
	vel = Vector3.zero
	local rx, ry, rz = cf:ToEulerAnglesYXZ()
	pitch = math.clamp(rx, -PITCH_LIMIT, PITCH_LIMIT)
	yaw, roll = ry, rz
	wantPitch, wantYaw, wantRoll = pitch, yaw, roll
	fov = camera.FieldOfView
	wantFov = fov
	speed = SPEED_DEFAULT

	camera.CameraType = Enum.CameraType.Scriptable
	UserInputService.MouseBehavior = Enum.MouseBehavior.LockCenter
	UserInputService.MouseIconEnabled = false

	freeze(player.Character)
	buildGui()
	layoutGui()
	overlayOn = true
	setUiHidden(true)
	refreshOverlay()
	showLegend()

	RunService:BindToRenderStep("ToiletFarmFreecam", Enum.RenderPriority.Camera.Value + 1, step)
end

function Freecam.exit()
	if not active then return end
	active = false
	RunService:UnbindFromRenderStep("ToiletFarmFreecam")

	if charHidden then
		charHidden = false
		restoreChar()
	end
	setUiHidden(false)
	if gui then gui.Enabled = false end
	thaw()

	local camera = workspace.CurrentCamera
	local s = saved
	if camera and s then
		camera.FieldOfView = s.fov
		camera.CameraSubject = s.cameraSubject
		camera.CameraType = s.cameraType
		-- Scriptable is the one state the default camera will not take back on its
		-- own, so if that is somehow where we came from, hand back a working camera
		if camera.CameraType == Enum.CameraType.Scriptable then camera.CameraType = Enum.CameraType.Custom end
	end
	if s then
		UserInputService.MouseBehavior = s.mouseBehavior
		UserInputService.MouseIconEnabled = s.mouseIcon
	end
	saved = nil
end

function Freecam.toggle()
	if active then
		Freecam.exit()
	else
		Freecam.enter()
	end
end

function Freecam.isActive(): boolean
	return active
end

-- ── wiring ────────────────────────────────────────────────────────────────
local function mayFly(): boolean
	if allowed == nil then
		local ok = #ALLOW == 0
		for _, id in ipairs(ALLOW) do
			if id == player.UserId then
				ok = true
				break
			end
		end
		allowed = ok
	end
	return allowed == true
end

function Freecam.init()
	-- the control module is a CoreScript, so it is not ours and may not be there
	local scripts = player:FindFirstChild("PlayerScripts")
	local module = scripts and scripts:WaitForChild("PlayerModule", 8)
	if module and module:IsA("ModuleScript") then
		local ok, result = pcall(function()
			return (require(module) :: any):GetControls()
		end)
		controls = ok and result or nil
	end

	-- a respawn hands us a fresh humanoid, which arrives unfrozen and walkable
	player.CharacterAdded:Connect(function(char)
		if not active then return end
		task.wait(0.15)
		if active then freeze(char) end
	end)

	UserInputService.InputBegan:Connect(function(input, processed)
		if input.UserInputType ~= Enum.UserInputType.Keyboard then return end
		if UserInputService:GetFocusedTextBox() then return end

		if input.KeyCode == Enum.KeyCode.F then
			-- Shift+F, so it cannot be hit by accident mid-game, and never while typing
			local shift = UserInputService:IsKeyDown(Enum.KeyCode.LeftShift)
				or UserInputService:IsKeyDown(Enum.KeyCode.RightShift)
			if not shift then return end
			if not mayFly() then return end
			Freecam.toggle()
			return
		end

		-- everything below means something only while flying; the rest of the time
		-- the game keeps its keys
		if not active or processed then return end
		if input.KeyCode == Enum.KeyCode.H then
			setUiHidden(not uiHidden)
			overlayOn = not uiHidden
			refreshOverlay()
		elseif input.KeyCode == Enum.KeyCode.T then
			charHidden = not charHidden
			if charHidden then
				applyCharHidden()
			else
				restoreChar()
			end
		elseif input.KeyCode == Enum.KeyCode.BackSlash then
			wantFov = 70
			wantRoll = 0
			speed = SPEED_DEFAULT
			showReadout()
		end
	end)

	UserInputService.InputChanged:Connect(function(input, processed)
		if not active then return end
		if input.UserInputType == Enum.UserInputType.MouseMovement then
			wantYaw -= input.Delta.X * LOOK_SENS
			wantPitch = math.clamp(wantPitch - input.Delta.Y * LOOK_SENS, -PITCH_LIMIT, PITCH_LIMIT)
		elseif input.UserInputType == Enum.UserInputType.MouseWheel and not processed then
			speed = math.clamp(speed * SPEED_STEP ^ input.Position.Z, SPEED_MIN, SPEED_MAX)
			showReadout()
		end
	end)

	-- alt-tabbing away mid-flight otherwise leaves the mouse locked to a window that
	-- has stopped listening
	UserInputService.WindowFocusReleased:Connect(function()
		if active then UserInputService.MouseBehavior = Enum.MouseBehavior.Default end
	end)
	UserInputService.WindowFocused:Connect(function()
		if active then UserInputService.MouseBehavior = Enum.MouseBehavior.LockCenter end
	end)
end

return Freecam
