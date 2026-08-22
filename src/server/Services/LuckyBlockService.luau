--!strict
-- LuckyBlockService — blocks spawn on your plot, you walk into one, a menu opens,
-- and opening it awards you a TOILET, rolled a few tiers above what you can
-- currently buy. (It used to roll a mutation onto a toilet you already owned.)

local Players = game:GetService("Players")
local ServerStorage = game:GetService("ServerStorage")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.ToiletConfig)
local Net = require(Shared.Net)
local DataService = require(script.Parent.DataService)
local PlotService = require(script.Parent.PlotService)
local ToiletService = require(script.Parent.ToiletService)
local PoopService = require(script.Parent.PoopService)
local IndexService = require(script.Parent.IndexService)

local BlockModels = ServerStorage.Assets:WaitForChild("LuckyBlocks")
local PromptEvent = Net.event(Net.NAMES.LuckyPrompt)
local ResultEvent = Net.event(Net.NAMES.LuckyResult)
local ToastEvent  = Net.event(Net.NAMES.Toast)

local LuckyBlockService = {}

-- live blocks in the world: [uid] = { model, blockId, owner }
local live: { [string]: any } = {}
local nextUid = 0

local function uid(): string
	nextUid += 1
	return "lb" .. nextUid
end

-- luck perks shift the roll toward the rare end by re-rolling low results
local function luckBonus(player: Player): number
	local p = DataService.get(player)
	if not p then return 0 end
	local bonus = 0.10 * (p.perks.LuckyGut or 0)
	if p.discovered["__ALL_MUTATIONS"] then bonus += Config.INDEX_ALL_MUTATIONS_LUCK end
	return bonus
end

-- The tier a block is rolled against: what the player can buy right now, so a
-- block never awards something they could already purchase for pocket change.
function LuckyBlockService.baseTier(player: Player): number
	return ToiletService.currentBuyTier(player)
end

-- Rolls the tier this block awards. Returns the tier and the offset it rolled,
-- so the reveal can say how far above your Buy Tier you landed.
-- `luck` reweights the table toward the rarer outcomes; the Robux unlock passes
-- Config.LUCKY_ROBUX_LUCK, which is what the button's "400% LUCK" promises.
function LuckyBlockService.roll(player: Player, blockId: string, luck: number?): (number, number)
	local block = Config.luckyBlock(blockId)
	local base = LuckyBlockService.baseTier(player)
	if not block then return base, 0 end

	local offset = Config.rollLuckyOffset(blockId, luck)
	-- luck perk: one extra roll, keep the better of the two
	if math.random() < luckBonus(player) then
		offset = math.max(offset, Config.rollLuckyOffset(blockId, luck))
	end
	return Config.luckyTierFor(base, offset), offset
end

-- ── world blocks ─────────────────────────────────────────────────────────
function LuckyBlockService.spawnOnPlot(player: Player, blockId: string?)
	local plot = PlotService.plotFor(player)
	local p = DataService.get(player)
	if not plot or not p then return end

	blockId = blockId or Config.rollLuckyBlockId(p.rebirths)
	local def = Config.luckyBlock(blockId)
	if not def then return end
	local source = BlockModels:FindFirstChild(def.model)
	if not source then warn("[Lucky] missing model " .. def.model) return end

	-- A block comes OUT OF A TOILET and rides the belt down, exactly like a poop,
	-- rather than materialising next to the player.
	local owned = {}
	for _, t in ipairs(p.toilets) do
		local m = PlotService.toiletModel(plot, t.slot)
		if m then table.insert(owned, m) end
	end
	if #owned == 0 then return end   -- nothing to come out of yet
	local fromToilet = owned[math.random(#owned)]
	-- Onto the belt, at the exact point a poop appears. This used to be the toilet's
	-- own pivot, which is INSIDE the stall, so a 2.5 stud block spawned wedged under
	-- the model and never reached the belt. The extra lift clears the belt surface.
	local pos = PoopService.dropPoint(plot, fromToilet:GetPivot().Position) + Vector3.new(0, 1.5, 0)

	local model = source:Clone()
	model.Name = "LuckyBlock"
	local id = uid()
	model:SetAttribute("Uid", id)
	model:SetAttribute("BlockId", blockId)
	-- Same physics treatment as a poop, so the block rides the same belts: one rigid
	-- body, a single collider, low friction, and no collision with players.
	--
	-- The collider must be the block's BODY. These models ship with no PrimaryPart,
	-- and FindFirstChildWhichIsA returns whatever comes first in the hierarchy -- on
	-- the Basic block that is a 0.2 x 1.9 x 0.2 sliver of trim. With the body left
	-- CanCollide = false the whole block fell straight through the belt it was
	-- supposed to ride and came to rest on the floor below it, which is the "stuck"
	-- the pad was reported for. Take the largest part instead.
	local primary = model.PrimaryPart
	if not primary then
		for _, d in ipairs(model:GetDescendants()) do
			if d:IsA("BasePart") and (not primary or d.Size.Magnitude > primary.Size.Magnitude) then
				primary = d
			end
		end
	end
	model.PrimaryPart = primary
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("BasePart") then
			d.Anchored = false
			d.CanQuery = false
			d.CustomPhysicalProperties = PhysicalProperties.new(1, 0.2, 0)
			d.CollisionGroup = "Poop"
			if d == primary then
				d.CanCollide = true
			else
				d.CanCollide = false
				-- decorations ride along without adding mass, as on the poops
				d.Massless = true
				local weld = Instance.new("WeldConstraint")
				weld.Part0 = d
				weld.Part1 = primary
				weld.Parent = primary
			end
		end
	end
	local _, size = model:GetBoundingBox()
	local dim = math.max(size.X, size.Y, size.Z)
	-- same ScaleTo caveat as the toilets: multiply the existing scale
	if dim > 0 then model:ScaleTo(model:GetScale() * (2.5 / dim)) end
	model:PivotTo(CFrame.new(pos))
	model.Parent = plot
	live[id] = { model = model, blockId = blockId, owner = player, born = os.clock() }

	-- nudged off the stall lip; the belts carry it the rest of the way
	if primary then
		local fwd = plot:GetPivot().LookVector
		primary.AssemblyLinearVelocity = fwd * 4 + Vector3.new(0, 1, 0)
	end

	-- proximity check → opens the menu for the owner
	task.spawn(function()
		while model.Parent and live[id] do
			local char = player.Character
			local hrp = char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
			if hrp and (hrp.Position - model:GetPivot().Position).Magnitude < 7 then
				LuckyBlockService.pickup(player, id)
				break
			end
			if os.clock() - live[id].born > Config.LUCKY_DESPAWN then
				live[id] = nil
				model:Destroy()
				break
			end
			task.wait(0.2)
		end
	end)

	return id
end

-- walking into a block puts it in your inventory and opens the menu
function LuckyBlockService.pickup(player: Player, id: string)
	local entry = live[id]
	if not entry or entry.owner ~= player then return end
	live[id] = nil
	if entry.model then entry.model:Destroy() end

	local p = DataService.get(player)
	if not p then return end

	-- The price is QUOTED here and stored on the block, then honoured at unlock.
	--
	-- It used to be recomputed at click time while the client worked its own out
	-- when it drew the panel, and the formula moves under both of them: the cash
	-- share climbs as Auto Collect banks money, and the expected-value term climbs
	-- with Total Toilets every time a toilet is bought or merged. So a player could
	-- be looking at "Unlock: $153" with $196 in hand, click, and be told they could
	-- not afford it -- because by then the server had decided on a bigger number.
	local cost = LuckyBlockService.unlockCost(player, entry.blockId)
	table.insert(p.luckyInv, { id = entry.blockId, uid = id, cost = cost })
	DataService.push(player, { luckyInv = p.luckyInv })
	PromptEvent:FireClient(player, { blockId = entry.blockId, uid = id, cost = cost })
end

local function takeFromInventory(player: Player, blockUid: string)
	local p = DataService.get(player)
	if not p then return nil end
	for i, e in ipairs(p.luckyInv) do
		if e.uid == blockUid then
			table.remove(p.luckyInv, i)
			return e
		end
	end
	return nil
end

-- Unlock price in cash. Priced off what the block will actually award and off the
-- player's balance — see Config.luckyUnlockCost.
function LuckyBlockService.unlockCost(player: Player, blockId: string): number
	local p = DataService.get(player)
	if not p then return Config.LUCKY_MIN_COST end
	return Config.luckyUnlockCost(
		blockId,
		LuckyBlockService.baseTier(player),
		ToiletService.totalToilets(player),
		p.cash)
end

function LuckyBlockService.open(player: Player, blockUid: string, paidWithRobux: boolean?)
	local p = DataService.get(player)
	if not p then return end
	local entry
	for _, e in ipairs(p.luckyInv) do if e.uid == blockUid then entry = e end end
	if not entry then return end

	-- The reward is a physical toilet, so it needs somewhere to go. Check before
	-- taking payment or consuming the block, otherwise a player with a full plot
	-- pays and gets nothing.
	if not PlotService.freeSlot(player) then
		ToastEvent:FireClient(player, "No free stalls — merge or buy more slots first!", "error")
		return
	end

	if not paidWithRobux then
		-- the price quoted when the block was picked up, so what the panel showed is
		-- what the player pays; only blocks saved before this fall back to a fresh one
		local cost = tonumber(entry.cost) or LuckyBlockService.unlockCost(player, entry.id)
		if p.cash < cost then
			ToastEvent:FireClient(player, "Not enough cash to unlock!", "error")
			return
		end
		p.cash -= cost
	end

	takeFromInventory(player, blockUid)
	-- paying Robux is what buys the luck, so it is read from the same flag that
	-- waived the cash price rather than from anything the client sent
	local tier, offset = LuckyBlockService.roll(player, entry.id,
		paidWithRobux and Config.LUCKY_ROBUX_LUCK or nil)

	local slot, why = ToiletService.grant(player, tier)
	if not slot then
		-- grant() already rolled itself back; hand the block back rather than
		-- silently eating it
		table.insert(p.luckyInv, entry)
		DataService.push(player, { luckyInv = p.luckyInv })
		ToastEvent:FireClient(player, "Couldn't place that toilet — try again.", "error")
		warn(("[Lucky] grant failed (%s) for tier %d"):format(tostring(why), tier))
		return
	end

	DataService.push(player)
	ResultEvent:FireClient(player, {
		blockId = entry.id,
		tier = tier,
		offset = offset,
		name = Config.displayName(tier),
		rarity = Config.rarityOf(tier),
	})
	return tier
end

function LuckyBlockService.discard(player: Player, blockUid: string)
	if takeFromInventory(player, blockUid) then
		local p = DataService.get(player)
		DataService.push(player, { luckyInv = p.luckyInv })
	end
end

function LuckyBlockService.grant(player: Player, blockId: string, count: number?)
	local p = DataService.get(player)
	if not p then return end
	for _ = 1, (count or 1) do
		table.insert(p.luckyInv, { id = blockId, uid = uid() })
	end
	DataService.push(player, { luckyInv = p.luckyInv })
end

function LuckyBlockService.init()
	Players.PlayerAdded:Connect(function(player)
		task.spawn(function()
			while player.Parent do
				local wait = math.random(Config.LUCKY_SPAWN_INTERVAL.min, Config.LUCKY_SPAWN_INTERVAL.max)
				task.wait(wait)
				if player.Parent and PlotService.plotFor(player) then
					LuckyBlockService.spawnOnPlot(player)
				end
			end
		end)
	end)

	Players.PlayerRemoving:Connect(function(player)
		for id, e in pairs(live) do
			if e.owner == player then
				if e.model then e.model:Destroy() end
				live[id] = nil
			end
		end
	end)
end

return LuckyBlockService
