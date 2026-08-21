--!strict
-- VfxService — the one-shot particle effects imported into ServerStorage.Assets.Vfx.
--
-- Every emitter in those models ships with Enabled = false: they are burst effects,
-- meant to be :Emit()ed once, not left streaming. Nothing in the game referenced the
-- folder, so all three were dead assets sitting in storage.
--
-- These play on the SERVER so every player in the server sees them. A merge on your
-- farm should be visible to someone standing on it, which is the whole point of the
-- effect; a client-only burst would be invisible to visitors.

local ServerStorage = game:GetService("ServerStorage")
local Debris = game:GetService("Debris")

local VfxService = {}

local Vfx = ServerStorage.Assets:FindFirstChild("Vfx")

-- key used by callers -> model name in ServerStorage.Assets.Vfx
local EFFECTS = {
	merge    = "merge effect",
	cash     = "cash effect",
	confetti = "confetti effect",
}

local DEFAULT_BURST = 18

local templates: { [string]: BasePart } = {}
local warned: { [string]: boolean } = {}

local function templateFor(key: string): BasePart?
	local cached = templates[key]
	if cached then return cached end

	local name = EFFECTS[key]
	local source = name and Vfx and Vfx:FindFirstChild(name)
	if not source or not source:IsA("BasePart") then
		if not warned[key] then
			warned[key] = true
			warn(("[VfxService] missing effect %q in ServerStorage.Assets.Vfx"):format(key))
		end
		return nil
	end

	local part = source:Clone()
	-- the source parts are anchored, invisible emitter carriers; make sure a clone
	-- can never collide with a player or block a raycast
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.Transparency = 1
	part.CastShadow = false
	templates[key] = part
	return part
end

-- the longest emitter lifetime, so cleanup never cuts particles off mid-flight
local function lifespanOf(part: BasePart): number
	local longest = 1
	for _, d in ipairs(part:GetDescendants()) do
		if d:IsA("ParticleEmitter") then
			longest = math.max(longest, d.Lifetime.Max)
		end
	end
	return longest + 0.5
end

function VfxService.play(key: string, position: Vector3, burst: number?)
	local template = templateFor(key)
	if not template then return end

	local part = template:Clone()
	part.CFrame = CFrame.new(position)
	part.Parent = workspace

	local n = burst or DEFAULT_BURST
	for _, d in ipairs(part:GetDescendants()) do
		if d:IsA("ParticleEmitter") then
			-- a couple of these ship Enabled = true and would stream forever once the
			-- clone is in the world, so force the burst-only behaviour
			d.Enabled = false
			d:Emit(n)
		end
	end

	Debris:AddItem(part, lifespanOf(part))
end

-- Convenience: play at whatever the player is standing on.
function VfxService.playAt(player: Player, key: string, offset: Vector3?, burst: number?)
	local char = player.Character
	local hrp = char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not hrp then return end
	VfxService.play(key, hrp.Position + (offset or Vector3.new(0, -2, 0)), burst)
end

return VfxService
