--!strict
-- CodesService — redeemable codes. Cash rewards scale with the rebirth multiplier,
-- otherwise they're worthless past R3. Codes never grant toilets directly, because
-- that breaks the ladder pacing.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.ToiletConfig)
local Format = require(Shared.Format)
local Net = require(Shared.Net)
local DataService = require(script.Parent.DataService)
local LuckyBlockService = require(script.Parent.LuckyBlockService)

local ToastEvent = Net.event(Net.NAMES.Toast)

local CodesService = {}

-- cash values are pre-multiplier; they get scaled by the player's rebirth multiplier
CodesService.CODES = {
	RELEASE   = { cash = 5000,  tokens = 1 },
	FLUSH     = { cash = 2500 },
	POOPY     = { cash = 1000 },
	THRONE    = { lucky = "Green" },
	GOLDEN    = { lucky = "Ice" },
	LIKE1K    = { cash = 10000, tokens = 1 },
	CLEANUP   = { cash = 7500 },
}

function CodesService.redeem(player: Player, raw: string)
	local p = DataService.get(player)
	if not p then return end
	local code = tostring(raw or ""):upper():gsub("%s", "")
	if code == "" then return end

	local reward = CodesService.CODES[code]
	if not reward then
		ToastEvent:FireClient(player, "Invalid code!", "error")
		return
	end
	if p.codes[code] then
		ToastEvent:FireClient(player, "Code already used!", "error")
		return
	end
	p.codes[code] = true

	local parts = {}
	if reward.cash then
		local amount = reward.cash * Config.rebirthMultiplier(p.rebirths)
		p.cash += amount
		table.insert(parts, "$" .. Format.cash(amount))
	end
	if reward.tokens then
		p.tokens += reward.tokens
		table.insert(parts, reward.tokens .. " Flush Token" .. (reward.tokens > 1 and "s" or ""))
	end
	if reward.lucky then
		LuckyBlockService.grant(player, reward.lucky, 1)
		table.insert(parts, reward.lucky .. " Lucky Block")
	end

	DataService.push(player)
	ToastEvent:FireClient(player, "Redeemed: " .. table.concat(parts, " + "), "reward")
	return true
end

return CodesService
