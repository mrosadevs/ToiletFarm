--!strict
-- Audio — all sound playback, with the Settings sliders wired to real volumes.

local SoundService = game:GetService("SoundService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local SoundIds = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("SoundIds"))

local Audio = {}

local sfxVolume = 0.8
local musicVolume = 0.5
local muteToilets = false

local group = Instance.new("Folder")
group.Name = "ClientSounds"
group.Parent = SoundService

local music: Sound? = nil

-- Sounds that count as "toilet noise" for the Mute Toilets setting, and it is only
-- the flush. This used to take PoopPlop and PoopDeposit with it, which are the
-- pickup and the deposit -- the player's own actions, not a toilet. Between them
-- and the flush that is every sound the core loop makes, so switching one toilet
-- setting on silenced the whole game and left only UI clicks and footsteps; and
-- because the setting is saved, it stayed silent across rejoins. The flush is the
-- noise somebody wants gone: it fires on every single drop, dozens a second on a
-- full farm.
local TOILET_SOUNDS = { Flush = true }

function Audio.play(name: string, opts: any?)
	local id = SoundIds[name]
	if not id then
		warn("[Audio] unknown sound " .. name)
		return
	end
	if muteToilets and TOILET_SOUNDS[name] then return end
	opts = opts or {}
	local s = Instance.new("Sound")
	s.SoundId = id
	s.Volume = (opts.volume or 1) * sfxVolume
	s.PlaybackSpeed = opts.speed or 1
	s.Parent = opts.parent or group
	-- A Sound parented to a part is positional, but Roblox's default falloff carries
	-- for hundreds of studs -- which is how a farm across the map ends up audible.
	-- `range` sets where it becomes silent, and it is inaudible beyond that.
	if opts.range and s.Parent and s.Parent:IsA("BasePart") then
		s.RollOffMode = Enum.RollOffMode.InverseTapered
		s.RollOffMinDistance = opts.minRange or 8
		s.RollOffMaxDistance = opts.range
	end
	s:Play()
	s.Ended:Connect(function() s:Destroy() end)
	-- safety net: some ids never fire Ended if they fail to load
	task.delay(12, function() if s.Parent then s:Destroy() end end)
	return s
end

-- slight pitch variation so repeated plops don't sound robotic
function Audio.playVaried(name: string, spread: number?)
	local s = spread or 0.12
	return Audio.play(name, { speed = 1 + (math.random() - 0.5) * 2 * s })
end

function Audio.startMusic()
	if music then return end
	local s = Instance.new("Sound")
	s.SoundId = SoundIds.Music
	s.Looped = true
	s.Volume = musicVolume * 0.4
	s.Parent = group
	s:Play()
	music = s
end

function Audio.applySettings(settings: any)
	if not settings then return end
	if type(settings.Sfx) == "number" then sfxVolume = settings.Sfx end
	if type(settings.Music) == "number" then
		musicVolume = settings.Music
		if music then music.Volume = musicVolume * 0.4 end
	end
	if type(settings.MuteToilets) == "boolean" then muteToilets = settings.MuteToilets end
end

return Audio
