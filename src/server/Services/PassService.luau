--!strict
-- PassService — gamepass + dev product ownership, cached per session.
--
-- ⚠ Fill in the ids below once the passes/products exist on the site. Everything is
--   wired already, so a zero id just means "nobody owns it" and the game plays on.

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Prices = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Prices"))

local PassService = {}

-- Injected by Main rather than required. DataService already reaches into
-- PassService for pass ownership, so requiring it back here would make the two
-- modules mutually dependent.
local DataService: any = nil

function PassService.bindData(service: any)
	DataService = service
end

-- name -> gamepass id. This is the complete list; there are no other passes.
PassService.PASSES = {
	AutoFlush  = 1949349575,  -- "Auto Collect Poops"
	AutoCash   = 1948857557,  -- "Auto Collect Cash"
	DoublePoop = 1949439531,  -- "Double Poops" — x2 poop value
	DoubleCash = 1948365646,  -- "x2 Cash" — doubles cash on deposit
}

-- name -> dev product id. This is the complete list; there are no other products.
PassService.PRODUCTS = {
	FinishProcessing = 3708565166,  -- "Instant Poop Process" — the Finish Now pad
	PoopPack1        = 3708565222,  -- small cash pack
	PoopPack2        = 3708565345,  -- medium cash pack
	PoopPack3        = 3708565384,  -- large cash pack
	-- one product per Lucky Block tier
	LuckyBasic       = 3708596231,
	LuckyGreen       = 3708596305,
	LuckyIce         = 3708596407,
	LuckyPurple      = 3708596472,
	LuckyWhite       = 3708596562,
	-- Welcome Back modal only: doubles the offline poop claim
	DoubleOffline    = 3708663796,
}

local cache: { [number]: { [string]: boolean } } = {}

function PassService.has(player: Player, passName: string): boolean
	local id = PassService.PASSES[passName]
	if not id or id == 0 then return false end
	local byUser = cache[player.UserId]
	if byUser and byUser[passName] ~= nil then return byUser[passName] end

	local owns = false
	local ok, res = pcall(function()
		return MarketplaceService:UserOwnsGamePassAsync(player.UserId, id)
	end)
	if ok then owns = res end

	cache[player.UserId] = byUser or {}
	cache[player.UserId][passName] = owns
	return owns
end

function PassService.productId(name: string): number
	return PassService.PRODUCTS[name] or 0
end

function PassService.passId(name: string): number
	return PassService.PASSES[name] or 0
end

-- ── live prices ─────────────────────────────────────────────────────────
-- The walk-on pads ship with mockup Robux numbers baked into their holograms.
-- Read the real price off the product instead, so the world can never advertise
-- a price that differs from what the purchase prompt charges.
local priceCache: { [string]: number } = {}
local priceFetching: { [string]: boolean } = {}

local function fetchPrice(cacheKey: string, id: number, infoType: Enum.InfoType)
	if priceFetching[cacheKey] then return end
	priceFetching[cacheKey] = true
	task.spawn(function()
		local ok, info = pcall(function()
			return MarketplaceService:GetProductInfo(id, infoType)
		end)
		if ok and info and info.PriceInRobux then
			priceCache[cacheKey] = info.PriceInRobux
		else
			warn(("[PassService] could not read price for %s (%d)"):format(cacheKey, id))
		end
		priceFetching[cacheKey] = nil
	end)
end

-- Returns nil until the async lookup lands; callers should leave the label alone.
function PassService.passPrice(name: string): number?
	local id = PassService.PASSES[name]
	if not id or id == 0 then return nil end
	local key = "pass_" .. name
	if priceCache[key] then return priceCache[key] end
	fetchPrice(key, id, Enum.InfoType.GamePass)
	return nil
end

function PassService.productPrice(name: string): number?
	local id = PassService.PRODUCTS[name]
	if not id or id == 0 then return nil end
	local key = "prod_" .. name
	if priceCache[key] then return priceCache[key] end
	fetchPrice(key, id, Enum.InfoType.Product)
	return nil
end

-- warm the cache at boot so the first pad refresh already has numbers
function PassService.prefetchPrices()
	for name, id in pairs(PassService.PASSES) do
		if id ~= 0 then fetchPrice("pass_" .. name, id, Enum.InfoType.GamePass) end
	end
	for name, id in pairs(PassService.PRODUCTS) do
		if id ~= 0 then fetchPrice("prod_" .. name, id, Enum.InfoType.Product) end
	end
end

-- handlers registered by other services: [productName] = function(player) -> boolean
local productHandlers: { [string]: (Player) -> boolean } = {}

function PassService.onProduct(name: string, handler: (Player) -> boolean)
	productHandlers[name] = handler
end

-- Push every known price onto attributes of ReplicatedStorage.Prices. Attributes
-- replicate by themselves, so client UI can read the same number the purchase
-- prompt will charge without any extra remote or hardcoded figure.
-- Cross-check the live API against the dashboard table in Shared.Prices.
-- GetProductInfo reports ceil(buyerPrice * 0.9), so a mismatch means a price was
-- changed on the site and Prices.DASHBOARD is now stale.
local warnedPrice: { [string]: boolean } = {}
function PassService.publishPrices()
	local checked, drifted = 0, 0
	local function check(kind: string, name: string, live: number?)
		if not live then return end
		checked += 1
		local key = kind .. "_" .. name
		local buyer = Prices.DASHBOARD[key]
		if not buyer then
			if not warnedPrice[key] then
				warnedPrice[key] = true
				warn(("[Prices] %s is not in Prices.DASHBOARD — add it (API reports %d, so buyer price is about %d)")
					:format(key, live, math.ceil(live / 0.9)))
			end
			return
		end
		if live ~= Prices.expectedApi(buyer) then
			drifted += 1
			if not warnedPrice[key] then
				warnedPrice[key] = true
				warn(("[Prices] %s changed on the site. API reports %d, which means a buyer price of about %d, but Prices.DASHBOARD still says %d — update it.")
					:format(key, live, math.ceil(live / 0.9), buyer))
			end
		end
	end
	for name in pairs(PassService.PASSES) do check("pass", name, PassService.passPrice(name)) end
	for name in pairs(PassService.PRODUCTS) do check("prod", name, PassService.productPrice(name)) end
	return checked, drifted
end

-- Keep the ledger bounded. Roblox gives up on a receipt long before a player could
-- accumulate this many, so the oldest entries are safe to forget.
local RECEIPT_HISTORY = 200

function PassService.trimReceipts(profile)
	local receipts = profile.receipts
	if type(receipts) ~= "table" then return end
	local keys = {}
	for k in pairs(receipts) do table.insert(keys, k) end
	if #keys <= RECEIPT_HISTORY then return end
	table.sort(keys, function(a, b)
		return (tonumber(receipts[a]) or 0) < (tonumber(receipts[b]) or 0)
	end)
	for i = 1, #keys - RECEIPT_HISTORY do
		receipts[keys[i]] = nil
	end
end

function PassService.init()
	PassService.prefetchPrices()

	-- prices arrive asynchronously, so republish until they have all landed and
	-- then keep them fresh in case one is changed on the site mid-session
	task.spawn(function()
		while true do
			PassService.publishPrices()
			task.wait(15)
		end
	end)

	Players.PlayerRemoving:Connect(function(player)
		cache[player.UserId] = nil
	end)

	-- a fresh purchase must invalidate the cache or the pass looks unowned until rejoin
	MarketplaceService.PromptGamePassPurchaseFinished:Connect(function(player, passId, purchased)
		if not purchased then return end
		cache[player.UserId] = nil
		for name, id in pairs(PassService.PASSES) do
			if id == passId then
				print(("[PassService] %s bought %s"):format(player.Name, name))
			end
		end
	end)

	-- Roblox retries a receipt until it is told PurchaseGranted, and it may retry one
	-- it has already delivered. Two rules keep that honest:
	--   * a PurchaseId already in the player's ledger is granted again immediately,
	--     without re-running the handler, so a retry can never pay out twice;
	--   * PurchaseGranted is only returned once the ledger entry is durably saved,
	--     because that answer permanently retires the receipt. Reporting success on
	--     a grant that only exists in memory is how a player pays and gets nothing.
	MarketplaceService.ProcessReceipt = function(receipt)
		local player = Players:GetPlayerByUserId(receipt.PlayerId)
		if not player then
			-- they left mid-purchase; tell Roblox to retry on their next join
			return Enum.ProductPurchaseDecision.NotProcessedYet
		end

		local profile = DataService and DataService.get(player)
		if not profile then
			-- profile still loading, or the load failed; retry rather than grant blind
			return Enum.ProductPurchaseDecision.NotProcessedYet
		end

		local purchaseKey = tostring(receipt.PurchaseId)
		profile.receipts = profile.receipts or {}
		if profile.receipts[purchaseKey] then
			return Enum.ProductPurchaseDecision.PurchaseGranted
		end

		for name, id in pairs(PassService.PRODUCTS) do
			if id == receipt.ProductId then
				local handler = productHandlers[name]
				if not handler then
					warn("[PassService] no handler for product " .. name)
					return Enum.ProductPurchaseDecision.NotProcessedYet
				end

				local ok, granted = pcall(handler, player)
				if not ok then
					warn(("[PassService] handler for %s errored: %s"):format(name, tostring(granted)))
					return Enum.ProductPurchaseDecision.NotProcessedYet
				end
				if not granted then
					return Enum.ProductPurchaseDecision.NotProcessedYet
				end

				profile.receipts[purchaseKey] = os.time()
				PassService.trimReceipts(profile)

				if not DataService.save(player) then
					-- The grant is real but not yet durable. Roll the ledger entry back and
					-- let Roblox retry; the handler stays un-run so the retry re-grants.
					profile.receipts[purchaseKey] = nil
					warn(("[PassService] could not persist receipt %s for %s; asking for a retry")
						:format(purchaseKey, player.Name))
					return Enum.ProductPurchaseDecision.NotProcessedYet
				end

				print(("[PassService] %s purchased %s (receipt %s)"):format(player.Name, name, purchaseKey))
				return Enum.ProductPurchaseDecision.PurchaseGranted
			end
		end
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end
end

return PassService
