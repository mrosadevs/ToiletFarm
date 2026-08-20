--!strict
-- State — the client's mirror of the server profile, plus a tiny change signal.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Net = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Net"))

local State = {}

State.data = {
	cash = 0, poops = 0, poopItems = 0, rebirths = 0, tokens = 0, processing = 0,
	toilets = {}, upgrades = {}, perks = {}, discovered = {}, luckyInv = {},
	settings = { Music = 0.5, Sfx = 0.8, MuteToilets = false, AutoPoop = false, AutoCash = false },
	stats = { playtime = 0, totalDeposited = 0, bestCash = 0 },
	tutorial = 1, carryCap = 25, slots = 8, maxTier = 6, multiplier = 1,
}

local listeners: { (any, any) -> () } = {}

-- fn(data, changedKeys)
function State.onChanged(fn: (any, any) -> ())
	table.insert(listeners, fn)
	return function()
		local i = table.find(listeners, fn)
		if i then table.remove(listeners, i) end
	end
end

function State.init()
	Net.event(Net.NAMES.StateChanged).OnClientEvent:Connect(function(partial)
		local changed = {}
		for k, v in pairs(partial) do
			State.data[k] = v
			changed[k] = true
		end
		for _, fn in ipairs(listeners) do
			task.spawn(fn, State.data, changed)
		end
	end)
	Net.event(Net.NAMES.RequestState):FireServer()
end

return State
