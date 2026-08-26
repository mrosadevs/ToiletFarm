--!strict
-- IndexService — permanent discovery record. Survives rebirth; it's the only long-run
-- collection goal in the game, so nothing here is ever wiped.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.ToiletConfig)
local Net = require(Shared.Net)
local DataService = require(script.Parent.DataService)

local DiscoveredEvent = Net.event(Net.NAMES.Discovered)
local ToastEvent = Net.event(Net.NAMES.Toast)

local IndexService = {}

local function tierFromKey(key: string): number?
	local n = key:match("^T(%d%d)_")
	return n and tonumber(n) or nil
end

function IndexService.counts(player: Player): number
	local p = DataService.get(player)
	if not p then return 0 end
	local toilets = 0
	for t = 1, Config.MAX_TIER do
		if p.discovered[Config.assetId(t)] then
			toilets += 1
		end
	end
	return toilets
end

-- Returns true if this was genuinely new, so callers can chain a celebration.
function IndexService.discover(player: Player, key: string): boolean
	local p = DataService.get(player)
	if not p or p.discovered[key] then return false end

	-- Only toilet tiers are tracked. Anything else is not a discovery.
	local tier = tierFromKey(key)
	if not tier then return false end

	local beforeToilets = IndexService.counts(player)
	p.discovered[key] = true

	local displayName = Config.displayName(tier)
	local rarity = Config.rarityOf(tier)

	DiscoveredEvent:FireClient(player, {
		key = key,
		name = displayName,
		rarity = rarity,
		weight = Config.DISCOVERY_WEIGHT[rarity] or 1,
	})

	-- completion rewards
	local toilets = IndexService.counts(player)
	if
		math.floor(toilets / Config.INDEX_TOILET_REWARD_EVERY)
		> math.floor(beforeToilets / Config.INDEX_TOILET_REWARD_EVERY)
	then
		p.tokens += 1
		ToastEvent:FireClient(player, "Index milestone! +1 Flush Token", "reward")
	end
	if toilets >= Config.MAX_TIER and not p.discovered["__ALL_TOILETS"] then
		p.discovered["__ALL_TOILETS"] = true
		ToastEvent:FireClient(player, "INDEX COMPLETE! Permanent +25% income", "reward")
	end

	DataService.push(player, { discovered = p.discovered, tokens = p.tokens })
	return true
end

return IndexService
