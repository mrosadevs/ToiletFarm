--!strict
-- FlushMeterService — the server-wide deposit multiplier that re-rolls every 30s.
-- This is the single biggest lever making the game active rather than idle: it pays
-- at the moment you deposit, so a good roll is worth sprinting for.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.ToiletConfig)
local Net = require(Shared.Net)

local MeterEvent = Net.event(Net.NAMES.FlushMeter)

local FlushMeterService = {}

local current = 1.0
local nextRollAt = 0

function FlushMeterService.multiplier(): number
	return current
end

function FlushMeterService.state()
	return { mult = current, nextRollAt = nextRollAt, period = Config.FLUSH_METER.period }
end

local function broadcast(player: Player?)
	local payload = FlushMeterService.state()
	if player then
		MeterEvent:FireClient(player, payload)
	else
		MeterEvent:FireAllClients(payload)
	end
end

-- The Flush Meter lives on the HUD only. It must NOT write to the plot's
-- "Selling Poop…" board — that board belongs to the processing queue and both
-- were fighting over the same Amount / PerSecond labels.

function FlushMeterService.init()
	Players.PlayerAdded:Connect(function(player)
		task.wait(1)
		broadcast(player)
	end)

	task.spawn(function()
		while true do
			current = Config.rollFlushMeter()
			nextRollAt = workspace:GetServerTimeNow() + Config.FLUSH_METER.period
			broadcast()
			task.wait(Config.FLUSH_METER.period)
		end
	end)
end

return FlushMeterService
