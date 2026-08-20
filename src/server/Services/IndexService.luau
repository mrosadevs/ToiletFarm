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

function IndexService.counts(player: Player): (number, number)
	local p = DataService.get(player)
	if not p then return 0, 0 end
	local toilets, mutations = 0, 0
	for t = 1, Config.MAX_TIER do
		if p.discovered[Config.assetId(t)] then toilets += 1 end
	end
	for _, m in ipairs(Config.MUTATION_ORDER) do
		if p.discovered["MUT_" .. m] then mutations += 1 end
	end
	return toilets, mutations
end

-- Returns true if this was genuinely new, so callers can chain a celebration.
function IndexService.discover(player: Player, key: string): boolean
	local p = DataService.get(player)
	if not p or p.discovered[key] then return false end

	local beforeToilets = select(1, IndexService.counts(player))
	p.discovered[key] = true

	local tier = tierFromKey(key)
	local displayName, rarity
	if tier then
		displayName = Config.displayName(tier)
		rarity = Config.rarityOf(tier)
	else
		displayName = key:gsub("^MUT_", "")
		rarity = "Legendary"
	end

	DiscoveredEvent:FireClient(player, {
		key = key,
		name = displayName,
		rarity = rarity,
		weight = Config.DISCOVERY_WEIGHT[rarity] or 1,
		isMutation = tier == nil,
	})

	-- completion rewards
	local toilets, mutations = IndexService.counts(player)
	if tier and math.floor(toilets / Config.INDEX_TOILET_REWARD_EVERY)
	         > math.floor(beforeToilets / Config.INDEX_TOILET_REWARD_EVERY) then
		p.tokens += 1
		ToastEvent:FireClient(player, "Index milestone! +1 Flush Token", "reward")
	end
	if toilets >= Config.MAX_TIER and not p.discovered["__ALL_TOILETS"] then
		p.discovered["__ALL_TOILETS"] = true
		ToastEvent:FireClient(player, "INDEX COMPLETE! Permanent +25% income", "reward")
	end
	if mutations >= #Config.MUTATION_ORDER and not p.discovered["__ALL_MUTATIONS"] then
		p.discovered["__ALL_MUTATIONS"] = true
		ToastEvent:FireClient(player, "All mutations found! +10% Lucky Block luck", "reward")
	end

	DataService.push(player, { discovered = p.discovered, tokens = p.tokens })
	return true
end

return IndexService
