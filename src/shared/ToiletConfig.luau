--!strict
-- ToiletConfig — single source of truth for the whole economy.
-- Retuning the game means editing INCOME_RATIO / COST_RATIO and nothing else.

local Config = {}

Config.MERGE_COUNT  = 3
-- Two invariants hold this economy together, and both are one-directional:
--   INCOME_RATIO > MERGE_COUNT  or merging three toilets loses you income.
--   INCOME_RATIO > COST_RATIO   or each tier costs more than it can ever earn,
--                                 so climbing tiers is a trap and the game stalls.
-- COST_RATIO used to be 4.0 against an income ratio of 3.6, i.e. inverted.
Config.INCOME_RATIO = 3.6
Config.COST_RATIO   = 3.3
Config.BASE_INCOME  = 0.5   -- cash/sec at T1
Config.BASE_COST   = 10
Config.MAX_TIER     = 30

-- Flat drop rate for every tier. A tier's earnings are anchored by
-- incomePerSecond(), and poopValue() is derived from it, so this interval does
-- NOT change what a tier earns — it only sets how many physical poops that
-- income arrives as. The old per-tier table ran 4.0s at T1 down to 1.5s at T30
-- (with two stray outliers at T21/T22), which quietly tripled the physics body
-- count on a late-game plot for no gameplay difference.
Config.DROP_INTERVAL = 3.0

-- Roblox ships characters at 16. The farm is a walking game -- stall to septic tank
-- to collect pad and back -- and 16 makes that a trudge.
Config.WALK_SPEED = 20

Config.NAMES = {
	"PorcelainStarter", "PrimitivePit", "MossyBowl", "RustyPan", "DumpsterDeluxe",
	"BrickThrone", "CopperComode", "SteelShrine", "PyramidToilet", "FreshFlow",
	"BurgerBowl", "PlumberPipe", "BogBlossom", "GoldenFlush", "CinderSeat",
	"VoltSeat", "ObsidianOutlet", "DiamondSeat", "CodeCube", "NeonNomad",
	"MicroThrone", "MegaBowl", "StarChart", "UfoToilet", "NebulaPorcelain",
	"QuantumQuay", "ArcaneRunestool", "EternalThrone", "VoidVoyager", "AscensionAlter",
}

-- "PorcelainStarter" -> "Porcelain Starter"
local displayCache = {}
function Config.displayName(tier: number): string
	local raw = Config.NAMES[tier]
	if not raw then return "???" end
	if not displayCache[raw] then
		displayCache[raw] = (raw:gsub("(%l)(%u)", "%1 %2"))
	end
	return displayCache[raw]
end

function Config.incomePerSecond(tier: number): number
	return Config.BASE_INCOME * Config.INCOME_RATIO ^ (tier - 1)
end

-- base price of a tier, before the farm-size markup
function Config.buyCost(tier: number): number
	return Config.BASE_COST * Config.COST_RATIO ^ (tier - 1)
end

-- ── Farm-size price scaling ────────────────────────────────────────────
-- Toilets get dearer as the farm grows, exactly like the reference game: the tier
-- you buy never changes, but the price climbs with your Total Toilets (the
-- merge-equivalent figure, not the stall count).
--
-- Fitted against six reference readings, all at Buy Tier 1 with a base of $5:
--   total     0     1     3    12    29   1,448
--   price    $5    $7   $10   $24   $46  $1,241
-- price = base * (1 + COEFF * total^EXPONENT) reproduces every one of those to
-- within a few percent. Retune with these two constants alone.
Config.BUY_SCALE_COEFF    = 0.4366
Config.BUY_SCALE_EXPONENT = 0.871

-- ── Production price scaling ────────────────────────────────
-- The price must NEVER key off the player's cash. Three readings from the reference
-- game settle it: the balance ran $21.67M -> $6.66M -> $12.89M while the price held
-- at $13.65M for 100 to the dollar, moving only when the flock itself grew (82,701
-- -> 83,274). Their curve works out at an exponent of 0.851 against our 0.871, so
-- the farm-size curve above is already their rule.
--
-- What it does not survive is our income running hot for a given farm size: that
-- curve alone left 100 toilets at a few hundred thousand while the player sat on
-- $30M+. So there is a second floor, and it is a property of the FARM rather than
-- the wallet -- what the toilets produce per second. It holds still when you spend
-- or collect, exactly like the flock count does, and only moves when the farm does.
-- A full 100 batch costs about BUY_PRODUCTION_SECONDS of the farm's output.
--
-- Deliberately measured on the raw poop value, not on cash earned: folding in the
-- cash multiplier would put the price up for owning the x2 gamepass, which is
-- charging a player for buying something.
-- 300 throttled the farm hard enough that it never filled: every toilet cost three
-- seconds of the WHOLE farm's output, so buying could not outrun income and the
-- simulation sat at nine of twenty-four stalls for hours. 120 keeps a full batch of
-- 100 costing a couple of minutes of production -- still a real purchase, not the
-- pocket change the farm-size curve alone charges a rich player.
Config.BUY_PRODUCTION_SECONDS = 120
Config.BUY_PRODUCTION_BATCH   = 100

function Config.buyCostFor(tier: number, totalToilets: number, poopRate: number?): number
	local markup = 1 + Config.BUY_SCALE_COEFF * math.max(totalToilets, 0) ^ Config.BUY_SCALE_EXPONENT
	local curve = Config.buyCost(tier) * markup
	local floor = 0
	if poopRate and poopRate > 0 then
		floor = poopRate * Config.BUY_PRODUCTION_SECONDS / Config.BUY_PRODUCTION_BATCH
	end
	return math.floor(math.max(curve, floor))
end

function Config.dropInterval(_tier: number): number
	return Config.DROP_INTERVAL
end

function Config.poopValue(tier: number): number
	return Config.incomePerSecond(tier) * Config.dropInterval(tier)
end

-- How many POOPS one dropping counts as, as opposed to what it is worth. A Tier 8
-- toilet producing a single item the basket counts as "1" reads as though the tier
-- did nothing, because the basket is the number the player watches while carrying.
-- The tier drives the count, so a T8 drop is worth 8 times a T1's -- and nothing
-- like the value curve (3.6^tier), which would make the basket meaningless within a
-- few tiers.
--
-- SCALE exists purely so the numbers feel worth picking up: walking into a heap and
-- banking 1.2K reads as a haul where 120 reads as loose change. It is display only.
-- Nothing in the economy is counted in poops -- cash is computed from a dropping's
-- VALUE, which this does not touch -- so turning it up costs no balance. Everything
-- the player sees in poops derives from here (basket, deposit banner, selling sign,
-- offline claim, pickup popups, the tutorial's collect goal), so they all move
-- together.
Config.POOP_COUNT_SCALE = 10

function Config.poopCount(tier: number): number
	return math.max(1, math.floor(tier)) * Config.POOP_COUNT_SCALE
end

function Config.rarityOf(tier: number): string
	if tier <= 5 then return "Common"
	elseif tier <= 10 then return "Uncommon"
	elseif tier <= 15 then return "Rare"
	elseif tier <= 20 then return "Epic"
	elseif tier <= 25 then return "Legendary"
	elseif tier <= 29 then return "Mythic"
	else return "Divine" end
end

Config.RARITY_COLORS = {
	Common    = Color3.fromRGB(190, 190, 190),
	Uncommon  = Color3.fromRGB( 90, 220, 100),
	Rare      = Color3.fromRGB( 70, 160, 255),
	Epic      = Color3.fromRGB(190, 100, 255),
	Legendary = Color3.fromRGB(255, 190,  50),
	Mythic    = Color3.fromRGB(255,  85,  85),
	Divine    = Color3.fromRGB(255, 255, 255),
}

-- how big the discovery popup gets, by rarity band
Config.DISCOVERY_WEIGHT = {
	Common = 1, Uncommon = 1, Rare = 1.1, Epic = 1.2,
	Legendary = 1.35, Mythic = 1.5, Divine = 1.7,
}

-- model name in ServerStorage.Assets: "T07_CopperComode"
function Config.assetId(tier: number): string
	return string.format("T%02d_%s", tier, Config.NAMES[tier])
end

-- ── Mutations ───────────────────────────────────────────────────────────────
Config.MUTATIONS = {
	None    = 1,   Bubble = 1.5, Snow   = 2,  Slime  = 3,
	Gilded  = 5,   Inferno = 8,  Shadow = 15, Vortex = 25, Rainbow = 50,
}
-- ordered, so the Index shows them in power order
Config.MUTATION_ORDER = { "Bubble", "Snow", "Slime", "Gilded", "Inferno", "Shadow", "Vortex", "Rainbow" }

Config.MUTATION_COLORS = {
	Bubble  = Color3.fromRGB(120, 200, 255),
	Snow    = Color3.fromRGB(235, 245, 255),
	Slime   = Color3.fromRGB(110, 230,  90),
	Gilded  = Color3.fromRGB(255, 200,   0),
	Inferno = Color3.fromRGB(255, 110,  30),
	Shadow  = Color3.fromRGB( 60,  55,  75),
	Vortex  = Color3.fromRGB(170,  60, 255),
	Rainbow = Color3.fromRGB(255,   0, 200),
}

-- ── Lucky Blocks ────────────────────────────────────────────────────────────
-- A block awards a TOILET, not a mutation. `roll` maps a tier OFFSET to a weight:
-- offset 0 is a toilet of the tier you can already buy, offset 3 is three tiers
-- above it. Rolling relative to the player's Buy Tier (rather than at fixed tiers)
-- is what keeps a Basic block worth opening after a few rebirths.
-- `robux` is advisory only — the price actually shown and charged is read live from
-- the dev product via PassService.productPrice(), so this can never drift out of sync.
Config.LUCKY_BLOCKS = {
	{ id = "Basic",  model = "BasicLuckyBlock2",  icon = "rbxassetid://94087721134152",  robux = 25,
	  color = Color3.fromRGB(255, 200, 40),
	  roll = { [0]=60, [1]=25, [2]=10, [3]=4, [4]=1 } },
	{ id = "Green",  model = "GreenLuckyBlock2",  icon = "rbxassetid://76457194119026",  robux = 60,
	  color = Color3.fromRGB(90, 230, 90),
	  roll = { [0]=40, [1]=25, [2]=20, [3]=10, [4]=4, [5]=1 } },
	{ id = "Ice",    model = "IceLuckyBlock3",    icon = "rbxassetid://137365700048410", robux = 120,
	  color = Color3.fromRGB(140, 225, 255),
	  roll = { [0]=25, [1]=20, [2]=25, [3]=15, [4]=10, [5]=4, [6]=1 } },
	{ id = "Purple", model = "PurpleLuckyBlock2", icon = "rbxassetid://77803120887253", robux = 250,
	  color = Color3.fromRGB(190, 90, 255),
	  roll = { [0]=10, [1]=10, [2]=20, [3]=25, [4]=20, [5]=10, [6]=4, [7]=1 } },
	{ id = "White",  model = "WhiteLuckyBlock2",  icon = "rbxassetid://101024301124546", robux = 599,
	  color = Color3.fromRGB(255, 255, 255),
	  roll = { [1]=5, [2]=10, [3]=15, [4]=25, [5]=25, [6]=12, [7]=6, [8]=2 } },
}

-- highest offset any block can roll, so callers can iterate deterministically
Config.LUCKY_MAX_OFFSET = 8

-- Rolls a tier offset for a block. Iterating 0..LUCKY_MAX_OFFSET rather than with
-- pairs() keeps the result reproducible for a given seed.
function Config.rollLuckyOffset(blockId: string): number
	local block = Config.luckyBlock(blockId)
	if not block then return 0 end
	local total = 0
	for off = 0, Config.LUCKY_MAX_OFFSET do total += (block.roll[off] or 0) end
	if total <= 0 then return 0 end
	local r = math.random() * total
	for off = 0, Config.LUCKY_MAX_OFFSET do
		local w = block.roll[off]
		if w then
			r -= w
			if r <= 0 then return off end
		end
	end
	return 0
end

-- the tier a given offset lands on for a player sitting at `baseTier`
function Config.luckyTierFor(baseTier: number, offset: number): number
	return math.clamp(baseTier + offset, 1, Config.MAX_TIER)
end

-- "Total Toilets": merge-equivalents, so a Tier 4 counts as MERGE_COUNT^3.
-- Lives here because the client prices Lucky Blocks with it too, and the two
-- sides must not drift.
function Config.totalToiletsOf(toilets: { any }): number
	local n = 0
	for _, t in ipairs(toilets) do
		n += Config.MERGE_COUNT ^ ((t.tier or 1) - 1)
	end
	return n
end

-- ── Lucky Block unlock price ──────────────────────────────────────────
-- The old price was a flat fraction of a single tier's base cost, which came out
-- at about $2 on a fresh save and never moved — far too cheap to be a decision.
-- Two things now set it, whichever is larger:
--   • what the block is actually worth: the expected price of the toilet it will
--     award, marked up, so a rarer block that rolls higher tiers costs more; and
--   • a slice of the player's current balance, so it stays a real purchase no
--     matter how rich they get.
-- The cash share is per-block, not flat: on a flat share a rich player pays the
-- same for a Basic as for a White, because the share swamps the EV term and the
-- rarity stops mattering. Rank 1 asks 15% of the balance, rank 5 asks 45%.
Config.LUCKY_EV_MARKUP       = 1.5
Config.LUCKY_CASH_SHARE      = 0.15
Config.LUCKY_CASH_SHARE_STEP = 0.5   -- +50% of the base share per rank
Config.LUCKY_MIN_COST        = 100

function Config.luckyRank(blockId: string): number
	for i, b in ipairs(Config.LUCKY_BLOCKS) do
		if b.id == blockId then return i end
	end
	return 1
end

function Config.luckyCashShare(blockId: string): number
	local rank = Config.luckyRank(blockId)
	return Config.LUCKY_CASH_SHARE * (1 + Config.LUCKY_CASH_SHARE_STEP * (rank - 1))
end

-- expected cash value of the toilet a block will award
function Config.luckyExpectedValue(blockId: string, baseTier: number, totalToilets: number): number
	local block = Config.luckyBlock(blockId)
	if not block then return 0 end
	local total, sum = 0, 0
	for off = 0, Config.LUCKY_MAX_OFFSET do
		local w = block.roll[off]
		if w then
			total += w
			sum += w * Config.buyCostFor(Config.luckyTierFor(baseTier, off), totalToilets)
		end
	end
	if total <= 0 then return 0 end
	return sum / total
end

function Config.luckyUnlockCost(blockId: string, baseTier: number, totalToilets: number, cash: number): number
	local ev = Config.luckyExpectedValue(blockId, baseTier, totalToilets) * Config.LUCKY_EV_MARKUP
	local share = math.max(cash, 0) * Config.luckyCashShare(blockId)
	return math.floor(math.max(Config.LUCKY_MIN_COST, ev, share))
end

function Config.luckyBlock(id: string)
	for _, b in ipairs(Config.LUCKY_BLOCKS) do
		if b.id == id then return b end
	end
	return nil
end

-- how often a block spawns on a claimed plot, and how long it sits before despawning
Config.LUCKY_SPAWN_INTERVAL = { min = 150, max = 300 }
Config.LUCKY_DESPAWN        = 120
-- which block spawns, weighted by the player's rebirth level
function Config.rollLuckyBlockId(rebirths: number): string
	local w = {
		Basic  = 100,
		Green  = 10 + rebirths * 12,
		Ice    = math.max(0, (rebirths - 1) * 8),
		Purple = math.max(0, (rebirths - 3) * 5),
		White  = math.max(0, (rebirths - 5) * 3),
	}
	local total = 0
	for _, v in pairs(w) do total += v end
	local r = math.random() * total
	for _, b in ipairs(Config.LUCKY_BLOCKS) do
		r -= (w[b.id] or 0)
		if r <= 0 then return b.id end
	end
	return "Basic"
end

-- ── Flush Meter ─────────────────────────────────────────────────────────────
Config.FLUSH_METER = {
	-- Slow. At 30s the hologram bar was visibly racing and the number changed before
	-- a player could do anything about it, which makes it noise rather than a thing
	-- you plan a run around.
	period = 150,         -- seconds between re-rolls
	warn   = 15,          -- countdown shown before the re-roll
	table  = {
		{ mult = 0.5,  weight = 10 },
		{ mult = 0.75, weight = 15 },
		{ mult = 1.0,  weight = 30 },
		{ mult = 1.25, weight = 20 },
		{ mult = 1.5,  weight = 15 },
		{ mult = 2.0,  weight = 10 },
	},
}

function Config.rollFlushMeter(): number
	local total = 0
	for _, e in ipairs(Config.FLUSH_METER.table) do total += e.weight end
	local r = math.random() * total
	for _, e in ipairs(Config.FLUSH_METER.table) do
		r -= e.weight
		if r <= 0 then return e.mult end
	end
	return 1.0
end

-- ── Rebirths ────────────────────────────────────────────────────────────────
-- multipliers are ABSOLUTE, not cumulative
-- Costs are SOLVED against a simulation of the loop rather than picked by eye:
-- production, merging, the buy curve and the flush meter's weighted average (1.1375),
-- for a player who grows the farm and then banks. The target is a ten minute first
-- rebirth with each one after it meaningfully longer -- roughly x1.5 -- landing at
-- about eight hours of play to reach the last one.
--
--   1: 10m    2: 15m    3: 23m    4: 34m
--   5: 52m    6: 77m    7: 1.9h   8: 2.8h
--
-- The old table asked $300K for the first rebirth, which the same model puts at 25
-- minutes, and $1.35e18 for the last, which is unreachable inside a day.
--
-- What the model does NOT include, all of which make a real player faster: the Buy
-- Tier upgrade, the cash/value upgrades, lucky blocks, offline earnings, the group
-- pad and the cash packs. Treat these as a ceiling on pacing, not a promise, and
-- retune from the simulation rather than by nudging single rows.
Config.REBIRTHS = {
	{ cost = 19e3,    mult = 2,    tokens = 1  },
	{ cost = 400e3,   mult = 5,    tokens = 2  },
	{ cost = 3.3e6,   mult = 12,   tokens = 3  },
	{ cost = 19e6,    mult = 30,   tokens = 5  },
	{ cost = 110e6,   mult = 80,   tokens = 8  },
	{ cost = 640e6,   mult = 220,  tokens = 12 },
	{ cost = 4.6e9,   mult = 650,  tokens = 18 },
	{ cost = 32e9,    mult = 2000, tokens = 25 },
}
Config.MAX_REBIRTH = #Config.REBIRTHS

function Config.rebirthMultiplier(rebirths: number): number
	if rebirths <= 0 then return 1 end
	local e = Config.REBIRTHS[math.min(rebirths, Config.MAX_REBIRTH)]
	return e and e.mult or 1
end

function Config.rebirthCost(currentRebirths: number): number?
	local e = Config.REBIRTHS[currentRebirths + 1]
	return e and e.cost or nil
end

-- ── Buy Tier ────────────────────────────────────────────────────────────────
-- You always buy toilets of your current Buy Tier — never "the best you can
-- afford". Raising it is a deliberate mid-run purchase at the Upgrade Buy Tier
-- pad, gated on BOTH a cash cost and a total-toilet count. Each rebirth raises
-- the ceiling by 2, which is what "+2 New Buy Tiers" on the rebirth screen means.
-- The ceiling is a straight multiple of your rebirth count, floored at 1 so a
-- fresh player can still buy T1. This runs one tier tighter than the old
-- `1 + 2 * rebirths`, which handed out a free tier at every rebirth level.
-- ⚠ Note the first rebirth therefore only moves the ceiling 1 -> 2, while every
--   later one moves it by 2. The rebirth screen's "+2 New Buy Tiers" copy is
--   accurate from the second rebirth onward.
Config.BUY_TIERS_PER_REBIRTH = 2

function Config.maxBuyTier(rebirths: number): number
	local ceiling = Config.BUY_TIERS_PER_REBIRTH * rebirths
	return math.clamp(ceiling, 1, Config.MAX_TIER)
end

-- cash price to go from `tier` to `tier + 1`
function Config.buyTierCost(tier: number): number
	return math.floor(Config.buyCost(tier + 1) * 5000)
end

-- How many toilets (merge-equivalents, the "Total Toilets" figure) you must own to
-- raise the Buy Tier. The first rung was 10K, which is a long way past where a first
-- run gets to -- so the upgrade pad read as locked for most of the game. Halved, and
-- every rung above it follows from the same base.
Config.BUY_TIER_BASE_REQUIREMENT = 5000

function Config.buyTierRequirement(tier: number): number
	return Config.BUY_TIER_BASE_REQUIREMENT * (Config.MERGE_COUNT ^ (tier - 1))
end

-- kept for older call sites; the ceiling a player may ever buy at
function Config.maxBuyableTier(rebirths: number): number
	return Config.maxBuyTier(rebirths)
end

-- ── Upgrades (cash-bought, wiped on rebirth) ────────────────────────────────
Config.UPGRADE_COST_RATIO = 3.5
Config.UPGRADES = {
	FlushSpeed     = { levels = 10, base = 1000, per = 0.03, label = "Flush Speed",     suffix = "%% faster" },
	PoopValue      = { levels = 10, base = 2000, per = 0.10, label = "Poop Value",      suffix = "%% value"  },
	SepticCapacity = { levels = 10, base = 500,  per = 150,  label = "Septic Capacity", suffix = " carry"    },
	CollectRadius  = { levels = 10, base = 750,  per = 2,    label = "Collect Radius",  suffix = " studs"    },
	PlotSlots      = { levels = 12, base = 5000, per = 1,    label = "Plot Slots",      suffix = " slot"     },
}

-- Processing is levelled separately (see Config.PROCESSING) because its growth
-- curve is much steeper than the flat +10%/level upgrades above.
Config.UPGRADE_ORDER = { "FlushSpeed", "PoopValue", "SepticCapacity", "CollectRadius", "PlotSlots" }

function Config.upgradeCost(key: string, currentLevel: number): number?
	local u = Config.UPGRADES[key]
	if not u or currentLevel >= u.levels then return nil end
	return math.floor(u.base * Config.UPGRADE_COST_RATIO ^ currentLevel)
end

-- ── Processing (the "Selling Poop… / X per second" sign) ───────────────────────────
-- Depositing does not pay out instantly. Poop goes into a queue that sells at a
-- rate you upgrade with the "+X Per Second" pad; the cash lands on the Collect Cash
-- pad as it clears. "Finish Now" skips the wait for Robux. Resets on rebirth.
Config.PROCESSING = {
	baseRate   = 1,      -- poops/sec at level 0
	rateGrowth = 4,      -- x4 per level, so the sign reaches the 999M range late
	baseCost   = 500,
	costGrowth = 4.2,
	maxLevel   = 25,
	friendBoost = 0.10,  -- +10% rate per friend in the server
	maxFriendBoost = 1.0,
}

function Config.processRate(level: number, friends: number?): number
	local base = Config.PROCESSING.baseRate * Config.PROCESSING.rateGrowth ^ level
	local boost = math.min((friends or 0) * Config.PROCESSING.friendBoost, Config.PROCESSING.maxFriendBoost)
	return base * (1 + boost)
end

function Config.processCost(level: number): number?
	if level >= Config.PROCESSING.maxLevel then return nil end
	return math.floor(Config.PROCESSING.baseCost * Config.PROCESSING.costGrowth ^ level)
end

-- ── Carry cap ─────────────────────────────────────────────────────────
-- Counted in POOPS, not in value. The old 25 was sized for an 8-slot plot; a
-- starting farm is now 24 stalls dropping every 3s, i.e. ~8 poops/sec, so 25 filled
-- the tank in four seconds and the player was permanently capped.
-- At the flat 3s drop interval a 24-stall starter farm makes ~8 poops/sec and a
-- full 48-stall plot ~16/sec:
--   250 base  -> ~31s of runway on a starter farm
--   1,750 max -> ~110s at the late-game rate of ~16 poops/sec across 48 stalls
Config.BASE_CARRY  = 250
Config.CARRY_PER_LEVEL = 150
Config.BASE_RADIUS = 6

function Config.carryCap(septicLevel: number, extra: number?): number
	return Config.BASE_CARRY + Config.CARRY_PER_LEVEL * septicLevel + (extra or 0)
end

function Config.collectRadius(radiusLevel: number): number
	return Config.BASE_RADIUS + 2 * radiusLevel
end

-- 9 rows of 12. The map ships 4 rows (48); PlotService builds the rest at boot by
-- cloning the top row upward, so this number is the only place the ceiling lives.
-- Raising it further means more rows of stalls, not just a bigger number.
Config.MAX_PLOT_SLOTS = 108
Config.STALL_ROW = 12

-- 30 to start and +10 a rebirth, so the ceiling arrives exactly at the last rebirth
-- (30 + 8 x 10 = 110, clamped to 108) rather than long before it. The upgrade and
-- the perk are what get you there early.
Config.BASE_PLOT_SLOTS = 30
Config.SLOTS_PER_REBIRTH = 10

function Config.plotSlots(rebirths: number, purchased: number, passSlots: number?): number
	local n = Config.BASE_PLOT_SLOTS
		+ Config.SLOTS_PER_REBIRTH * rebirths
		+ math.min(purchased, 12)
		+ (passSlots or 0)
	return math.min(n, Config.MAX_PLOT_SLOTS)
end

-- ── Offline earnings ────────────────────────────────────────────────────────
Config.OFFLINE_RATE     = 0.40
Config.OFFLINE_CAP      = 8 * 60 * 60
Config.OFFLINE_CAP_PASS = 12 * 60 * 60
Config.OFFLINE_MIN_SHOW = 60

function Config.offlinePoop(rateAtLogout: number, secondsAway: number, hasPass: boolean): number
	local cap = hasPass and Config.OFFLINE_CAP_PASS or Config.OFFLINE_CAP
	local t = math.clamp(secondsAway, 0, cap)
	return math.floor(rateAtLogout * t * Config.OFFLINE_RATE)
end

-- The same window in physical poops rather than value, so the modal can quote the
-- number the basket will actually show and Claim can credit both.
function Config.offlineItems(itemRateAtLogout: number, secondsAway: number, hasPass: boolean): number
	local cap = hasPass and Config.OFFLINE_CAP_PASS or Config.OFFLINE_CAP
	local t = math.clamp(secondsAway, 0, cap)
	return math.floor(itemRateAtLogout * t * Config.OFFLINE_RATE)
end

-- ── Group reward pad ─────────────────────────────────────────
-- Standing on the group pad pays out every ten minutes, but only for members.
-- It is deliberately a slice of the balance rather than a flat sum: a fixed
-- number is either meaningless by the second rebirth or absurd on the first day.
Config.GROUP_REWARD = {
	cooldown = 600,
	floor    = 500,    -- what a brand new farm gets
	share    = 0.12,   -- ...or this much of the balance, whichever is larger
}

function Config.groupReward(cash: number): number
	return math.max(Config.GROUP_REWARD.floor, math.floor((cash or 0) * Config.GROUP_REWARD.share))
end

-- ── Cash packs ───────────────────────────────────────────────────────────
-- The three green buttons down the left of the HUD. What they pay scales with the
-- player's current balance, so they stay meaningful at every stage instead of
-- becoming worthless after the first rebirth.
--
-- Curve fitted to the reference game:
--   balance $5      -> 551 / 22.0K / 440.9K
--   balance $36,715 -> 1.01M / 40.2M / 804.7M
-- Pack 2 is always 40x pack 1; pack 3 is 20x pack 2. Pack 1 is sublinear in the
-- balance (the multiplier shrinks as you get richer), which both points agree on.
Config.CASH_PACKS = {
	coefficient = 140.5,   -- pack1 = coefficient * cash^exponent (fits both refs to <1%)
	exponent    = 0.845,
	floor       = 500,     -- so a broke player still gets something worth buying
	stepSmallToMedium = 40,
	stepMediumToLarge = 20,
}

-- index 1 = small, 2 = medium, 3 = large
function Config.cashPackAmount(cash: number, index: number): number
	local c = Config.CASH_PACKS
	local base = math.max(c.floor, c.coefficient * math.max(cash, 0) ^ c.exponent)
	if index >= 2 then base *= c.stepSmallToMedium end
	if index >= 3 then base *= c.stepMediumToLarge end
	return math.floor(base)
end

-- ── Flush Token meta shop ───────────────────────────────────────────────────
Config.TOKEN_PERKS = {
	{ id = "RichDiet",    cost = 3,  max = 10, label = "Rich Diet",   desc = "+5%% global income" },
	{ id = "ExtraPlot",   cost = 5,  max = 6,  label = "Extra Plot",  desc = "+1 starting plot slot" },
	{ id = "HeadStart",   cost = 8,  max = 1,  label = "Head Start",  desc = "Start each rebirth with 1 cap-tier toilet" },
	{ id = "LuckyGut",    cost = 10, max = 5,  label = "Lucky Gut",   desc = "+10%% Lucky Block luck" },
	{ id = "AutoCollect", cost = 25, max = 1,  label = "Auto-Collect", desc = "Poop auto-banks at half rate" },
}

-- ── Index completion rewards ────────────────────────────────────────────────
Config.INDEX_TOILET_REWARD_EVERY = 5   -- toilets discovered per Flush Token
Config.INDEX_ALL_TOILETS_BONUS   = 0.25 -- +25%% income
Config.INDEX_ALL_MUTATIONS_LUCK  = 0.10 -- +10%% lucky block luck

-- ── Deposit / carry ─────────────────────────────────────────────────────────
Config.PICKUP_COOLDOWN = 0.05
-- Ceiling on un-collected poop lying on a plot, to keep the part count sane. Raised
-- alongside the carry cap so the heap can actually build up.
-- ⚠ Past this the OLDEST poop is destroyed, which silently bins value the player
--   has not banked yet. Keep it comfortably above what a full belt holds.
-- Resting poops are unanchored so they pile with real physics, so this is a physics
-- budget as well as a part budget: 6 plots x 120 is about 720 bodies worst case,
-- and settled ones sleep.
Config.MAX_WORLD_POOPS_PER_PLOT = 120

return Config
