--!strict
-- VfxService — the one-shot particle effects authored in ServerStorage.Assets.Vfx.
--
-- Every emitter in those models ships Enabled = false: they are burst effects, meant
-- to be :Emit()ed once rather than left streaming.
--
-- These used to be played on the server: clone the carrier into Workspace, call
-- :Emit() on every emitter, let Debris clear it up. That looked correct and produced
-- nothing on screen. :Emit() replicates as an EVENT to the clients that already have
-- the part, and the emit was happening in the same frame the part was parented, so
-- it consistently landed before the part itself arrived. With emitter lifetimes of
-- 0.3-1.0s there is no second chance -- the whole burst is over before the client
-- could have rendered it.
--
-- So the templates are published to ReplicatedStorage once at boot and the server
-- only broadcasts "play KEY at POSITION". Each client builds and emits locally, in
-- one frame, with no replication in the path at all. Everyone in the server still
-- sees it -- the broadcast goes to all of them -- which was the reason it lived on
-- the server in the first place.

local ServerStorage = game:GetService("ServerStorage")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Net = require(ReplicatedStorage:WaitForChild("Shared").Net)

local VfxService = {}

local PlayEvent = Net.event(Net.NAMES.PlayVfx)
local DEFAULT_BURST = 18

-- key used by callers -> model name authored in ServerStorage.Assets.Vfx
local EFFECTS = {
	merge    = "merge effect",
	cash     = "cash effect",
	confetti = "confetti effect",
}

function VfxService.init()
	local source = ServerStorage:FindFirstChild("Assets")
	source = source and source:FindFirstChild("Vfx")
	if not source then
		warn("[VfxService] ServerStorage.Assets.Vfx is missing -- no effects will play")
		return
	end

	local folder = Instance.new("Folder")
	folder.Name = "VfxAssets"

	for key, name in pairs(EFFECTS) do
		local effect = source:FindFirstChild(name)
		if not effect or not effect:IsA("BasePart") then
			warn(("[VfxService] missing effect %q (%s)"):format(key, name))
			continue
		end
		local part = effect:Clone()
		-- keyed by the caller's name, so a rename in Studio is a warning here rather
		-- than a silently dead effect at a call site
		part.Name = key
		part.Anchored = true
		part.CanCollide = false
		part.CanQuery = false
		part.CanTouch = false
		part.Transparency = 1
		part.CastShadow = false
		-- a couple of these ship Enabled = true and would stream forever once a clone
		-- is in the world
		for _, d in ipairs(part:GetDescendants()) do
			if d:IsA("ParticleEmitter") then d.Enabled = false end
		end
		part.Parent = folder
	end

	folder.Parent = ReplicatedStorage
end

-- Broadcast: every client in the server plays it locally.
function VfxService.play(key: string, position: Vector3, burst: number?)
	if not EFFECTS[key] then
		warn(("[VfxService] unknown effect %q"):format(tostring(key)))
		return
	end
	PlayEvent:FireAllClients(key, position, burst or DEFAULT_BURST)
end

-- Convenience: play at whatever the player is standing on.
function VfxService.playAt(player: Player, key: string, offset: Vector3?, burst: number?)
	local char = player.Character
	local hrp = char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not hrp then return end
	VfxService.play(key, hrp.Position + (offset or Vector3.new(0, -2, 0)), burst)
end

return VfxService
