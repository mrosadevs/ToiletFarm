--!strict
-- Main — server entry point. Boots the services in dependency order and owns the
-- client-facing remote handlers.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local MarketplaceService = game:GetService("MarketplaceService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.ToiletConfig)
local Net = require(Shared.Net)

local Services = script.Parent.Services
local DataService       = require(Services.DataService)
local PassService       = require(Services.PassService)
local PlotService       = require(Services.PlotService)
local PoopService       = require(Services.PoopService)
local IndexService      = require(Services.IndexService)
local FlushMeterService = require(Services.FlushMeterService)
local ToiletService     = require(Services.ToiletService)
local EconomyService    = require(Services.EconomyService)
local LuckyBlockService = require(Services.LuckyBlockService)
local TutorialService   = require(Services.TutorialService)
local CodesService      = require(Services.CodesService)
local PadService        = require(Services.PadService)

PassService.init()
DataService.init()
PlotService.init()
PoopService.init()
FlushMeterService.init()
ToiletService.init()
EconomyService.init()
LuckyBlockService.init()
PadService.init()

-- Poops are free physics bodies now, so the character has to sit in its own
-- collision group or running through a heap punts it across the plot.
local function setCollisionGroup(character: Model)
	local function apply(part: Instance)
		if part:IsA("BasePart") then part.CollisionGroup = "Characters" end
	end
	for _, d in ipairs(character:GetDescendants()) do apply(d) end
	character.DescendantAdded:Connect(apply)
end

Players.PlayerAdded:Connect(function(player)
	if player.Character then task.spawn(setCollisionGroup, player.Character) end
	player.CharacterAdded:Connect(function(char) task.spawn(setCollisionGroup, char) end)
end)

-- ── join flow ───────────────────────────────────────────────────────────
local function onCharacter(player: Player)
	task.wait(0.3)
	PlotService.teleportToPlot(player)
end

Players.PlayerAdded:Connect(function(player)
	-- DataService.PlayerAdded runs first (connected earlier), so wait for the profile
	local deadline = os.clock() + 15
	while not DataService.isLoaded(player) and os.clock() < deadline do task.wait(0.1) end
	if not DataService.isLoaded(player) then return end

	local plot = PlotService.claim(player)
	if not plot then
		player:Kick("All farms are full right now — please try another server!")
		return
	end

	PlotService.rebuild(player)
	ToiletService.resetTimers(player)
	DataService.push(player)
	TutorialService.push(player)
	EconomyService.reportOffline(player)

	if player.Character then task.spawn(onCharacter, player) end
	player.CharacterAdded:Connect(function() task.spawn(onCharacter, player) end)
end)

Players.PlayerRemoving:Connect(function(player)
	TutorialService.reset(player)
end)

-- ── remote handlers ────────────────────────────────────────────────────
local N = Net.NAMES

Net.event(N.Merge).OnServerEvent:Connect(function(player)
	if not DataService.isLoaded(player) then return end
	local n = ToiletService.mergeAll(player)
	if n and n > 0 then TutorialService.notify(player, "merge", 1) end
end)

Net.event(N.Rebirth).OnServerEvent:Connect(function(player)
	if not DataService.isLoaded(player) then return end
	EconomyService.rebirth(player)
end)

Net.event(N.BuyUpgrade).OnServerEvent:Connect(function(player, key)
	if not DataService.isLoaded(player) then return end
	if type(key) ~= "string" then return end
	EconomyService.buyUpgrade(player, key)
end)

Net.event(N.BuyTokenPerk).OnServerEvent:Connect(function(player, id)
	if not DataService.isLoaded(player) then return end
	if type(id) ~= "string" then return end
	EconomyService.buyPerk(player, id)
end)

Net.event(N.OpenLucky).OnServerEvent:Connect(function(player, blockUid, useRobux)
	if not DataService.isLoaded(player) then return end
	if type(blockUid) ~= "string" then return end
	if useRobux then
		-- charge through a dev product; the handler below finishes the open
		local p = DataService.get(player)
		local entry
		for _, e in ipairs(p.luckyInv) do if e.uid == blockUid then entry = e end end
		if not entry then return end
		local id = PassService.productId("Lucky" .. entry.id)
		if id == 0 then
			Net.event(N.Toast):FireClient(player, "Robux unlock coming soon!", "error")
			return
		end
		player:SetAttribute("PendingLuckyUid", blockUid)
		MarketplaceService:PromptProductPurchase(player, id)
	else
		LuckyBlockService.open(player, blockUid, false)
	end
end)

Net.event(N.DiscardLucky).OnServerEvent:Connect(function(player, blockUid)
	if not DataService.isLoaded(player) then return end
	if type(blockUid) ~= "string" then return end
	LuckyBlockService.discard(player, blockUid)
end)

Net.event(N.RedeemCode).OnServerEvent:Connect(function(player, code)
	if not DataService.isLoaded(player) then return end
	if type(code) ~= "string" or #code > 40 then return end
	CodesService.redeem(player, code)
end)

Net.event(N.SetSetting).OnServerEvent:Connect(function(player, key, value)
	local p = DataService.get(player)
	if not p then return end
	if type(key) ~= "string" then return end
	local current = p.settings[key]
	if current == nil then return end
	if type(current) == "number" and type(value) == "number" then
		p.settings[key] = math.clamp(value, 0, 1)
	elseif type(current) == "boolean" and type(value) == "boolean" then
		p.settings[key] = value
	else
		return
	end
	DataService.push(player, { settings = p.settings })
end)

-- the Home button on the HUD: put the player back on their own island
local lastHome: { [Player]: number } = {}
Net.event(N.TeleportHome).OnServerEvent:Connect(function(player)
	if not DataService.isLoaded(player) then return end
	local now = os.clock()
	if lastHome[player] and now - lastHome[player] < 1 then return end
	lastHome[player] = now
	PlotService.teleportToPlot(player)
end)

Players.PlayerRemoving:Connect(function(player) lastHome[player] = nil end)

Net.event(N.ClaimOffline).OnServerEvent:Connect(function(player, doubled)
	if not DataService.isLoaded(player) then return end
	-- the x2 path must go through a purchase, never a client-supplied flag
	EconomyService.claimOffline(player, false)
end)

-- ── dev products ────────────────────────────────────────────────────────
PassService.onProduct("InstantRebirth", function(player)
	local p = DataService.get(player)
	if not p then return false end
	local cost = Config.rebirthCost(p.rebirths)
	if not cost then return false end
	p.cash = math.max(p.cash, cost)
	return EconomyService.rebirth(player) == true
end)

PassService.onProduct("FinishProcessing", function(player)
	player:SetAttribute("PendingFinishNow", nil)
	return EconomyService.finishProcessing(player) == true
end)

PassService.onProduct("DoubleOffline", function(player)
	return EconomyService.claimOffline(player, true) == true
end)

PassService.onProduct("LuckyBlockx10", function(player)
	for _ = 1, 10 do
		LuckyBlockService.grant(player, Config.rollLuckyBlockId((DataService.get(player) or {}).rebirths or 0))
	end
	return true
end)

-- Cash packs pay out relative to the player's balance at the moment of purchase,
-- matching the amount the HUD button was advertising. Computed server-side only.
for index, name in ipairs({ "PoopPack1", "PoopPack2", "PoopPack3" }) do
	PassService.onProduct(name, function(player)
		local p = DataService.get(player)
		if not p then return false end
		local amount = Config.cashPackAmount(p.cash, index)
		p.cash += amount
		DataService.push(player, { cash = p.cash })
		Net.event(Net.NAMES.CashCollected):FireClient(player, { amount = amount })
		return true
	end)
end

for _, block in ipairs(Config.LUCKY_BLOCKS) do
	PassService.onProduct("Lucky" .. block.id, function(player)
		local uid = player:GetAttribute("PendingLuckyUid")
		player:SetAttribute("PendingLuckyUid", nil)
		if type(uid) == "string" then
			LuckyBlockService.open(player, uid, true)
		else
			LuckyBlockService.grant(player, block.id, 1)
		end
		return true
	end)
end

-- ── Studio-only dev hooks ─────────────────────────────────────────────────
-- Set the attribute on a player to trigger the action. Never runs in a live game.
if game:GetService("RunService"):IsStudio() then
	local function hook(player: Player)
		player:GetAttributeChangedSignal("DevSpawnLucky"):Connect(function()
			local blockId = player:GetAttribute("DevSpawnLucky")
			if type(blockId) ~= "string" then return end
			LuckyBlockService.spawnOnPlot(player, blockId)
		end)
		-- fires the client feedback events after a delay, so a capture can be timed
		-- against them (task.delay from an external console does not survive)
		player:GetAttributeChangedSignal("DevFireFx"):Connect(function()
			local which = player:GetAttribute("DevFireFx")
			if type(which) ~= "string" then return end
			-- repeat for a while so an external screen capture cannot miss the window
			task.spawn(function()
				for _ = 1, 8 do
					local hrp = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
					local pos = hrp and hrp.Position
					if which == "deposit" then
						Net.event(N.Deposited):FireClient(player,
							{ poops = 12345, count = 87, cash = 18500, multiplier = 1.5 })
					elseif which == "cash" then
						Net.event(N.CashCollected):FireClient(player, { amount = 4200, pos = pos })
					elseif which == "poop" then
						local payload = {}
						for i = 1, 8 do table.insert(payload, { pos = pos, value = 250 * i }) end
						Net.event(N.PoopPickup):FireClient(player, payload, 9999, 12, 25)
					end
					task.wait(2)
				end
			end)
		end)
		player:GetAttributeChangedSignal("DevGiveCash"):Connect(function()
			local amount = player:GetAttribute("DevGiveCash")
			if type(amount) ~= "number" then return end
			local p = DataService.get(player)
			if not p then return end
			p.cash += amount
			DataService.push(player, { cash = p.cash })
		end)
	end
	for _, player in ipairs(Players:GetPlayers()) do hook(player) end
	Players.PlayerAdded:Connect(hook)
	print("[ToiletFarm] Studio dev hooks active (DevSpawnLucky / DevGiveCash)")
end

print("[ToiletFarm] server ready")
