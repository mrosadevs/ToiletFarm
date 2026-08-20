--!strict
-- Prices — the single source of truth for every Robux figure shown in the game.
--
-- ⚠ Do NOT read MarketplaceService:GetProductInfo().PriceInRobux for display.
--   Measured on this game, it returns exactly ceil(dashboardPrice * 0.9) for every
--   pass and product (7/7). That is the creator-set price; the number the player
--   is actually charged is the "Current price" column on the Creator Dashboard.
--   Showing the API value under-advertises every price by ~10%.
--
-- So DASHBOARD below is authoritative for display. PassService still reads the API
-- and warns if the ratio stops matching, which is the signal that a price was
-- changed on the site and this table needs updating.

local Prices = {}

-- Buyer-facing prices, straight from the Creator Dashboard "Current price" column.
-- Update here whenever a price changes on the site.
Prices.DASHBOARD = {
	pass_AutoFlush   = 67,   -- Auto Collect Poops
	pass_AutoCash    = 25,   -- Auto Collect Cash
	pass_DoublePoop  = 399,  -- Double Poops
	pass_DoubleCash  = 12,   -- x2 Cash

	prod_FinishProcessing = 15,   -- Instant Poop Process
	prod_PoopPack1        = 14,   -- Small Cash Pack
	prod_PoopPack2        = 100,  -- Medium Cash Pack
	prod_PoopPack3        = 720,  -- Large Cash Pack
	prod_LuckyBasic       = 25,
	prod_LuckyGreen       = 60,
	prod_LuckyIce         = 120,
	prod_LuckyPurple      = 250,
	prod_LuckyWhite       = 599,
	prod_DoubleOffline    = 67,   -- x2 Offline Poops (Welcome Back modal only)
}

local function read(key: string): number?
	return Prices.DASHBOARD[key]
end

function Prices.pass(name: string): number?
	return read("pass_" .. name)
end

function Prices.product(name: string): number?
	return read("prod_" .. name)
end

-- text for a label sitting next to a Robux glyph; "..." while unknown
function Prices.text(kind: string, name: string): string
	local v = (kind == "pass") and Prices.pass(name) or Prices.product(name)
	return v and tostring(v) or "..."
end

-- what GetProductInfo should report for a given buyer price, used for drift checks
function Prices.expectedApi(buyerPrice: number): number
	return math.ceil(buyerPrice * 0.9)
end

return Prices
