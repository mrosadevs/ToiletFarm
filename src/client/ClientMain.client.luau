--!strict
-- ClientMain — boots every controller and routes the server's feedback events.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Format = require(Shared.Format)
local Net = require(Shared.Net)

local Controllers = script.Parent:WaitForChild("Controllers")
local UIKit    = require(Controllers.UIKit)
local Audio    = require(Controllers.Audio)
local State    = require(Controllers.State)
local Screens  = require(Controllers.Screens)
local Popups   = require(Controllers.Popups)
local WorldFx  = require(Controllers.WorldFx)
local Hud      = require(Controllers.Hud)
local Index    = require(Controllers.Index)
local Panels   = require(Controllers.Panels)
local Lucky    = require(Controllers.Lucky)
local Tutorial = require(Controllers.Tutorial)

local player = Players.LocalPlayer

-- order matters: Popups builds the layer everything else draws into
Popups.init()
State.init()
Hud.init()
Screens.register("IndexScreen", function() Index.refresh() end)
Index.init()
Panels.init()
Lucky.init()
Tutorial.init()
Screens.buildIconRow()
WorldFx.bindPads()
WorldFx.muteVanillaSounds()
WorldFx.bindFootsteps()
WorldFx.bindPlotSounds()
WorldFx.buildFlushHologram()

-- the discovery ScreenGui is a popup we drive directly, not a panel
local discovery = player.PlayerGui:WaitForChild("DiscoveryPopup") :: ScreenGui
discovery.Enabled = false
discovery.ResetOnSpawn = false
discovery.DisplayOrder = 45
UIKit.bindScale(discovery)

Audio.startMusic()
Audio.applySettings(State.data.settings)

-- ── server feedback ────────────────────────────────────────────────────
local N = Net.NAMES

Net.event(N.PoopPickup).OnClientEvent:Connect(function(entries)
	Popups.poopBurst(entries)
end)

Net.event(N.CashCollected).OnClientEvent:Connect(function(payload)
	-- Only burst for a collection that happened somewhere in the world, i.e. the
	-- player walked onto the Collect Cash pad. Auto Collect fires this every tick
	-- with no position, and bursting on the character each time is maddening.
	if payload.pos then
		WorldFx.cashBurst(payload.pos, math.clamp(math.floor(payload.amount / 50), 8, 24))
	end
	Popups.toast("+" .. Format.cash(payload.amount) .. "$", "reward")
end)

Net.event(N.Deposited).OnClientEvent:Connect(function(payload)
	Popups.depositRain(payload.count or payload.poops)
end)

Net.event(N.Discovered).OnClientEvent:Connect(function(info)
	Popups.discovery(info)
	Index.refresh()
end)

Net.event(N.MergeResult).OnClientEvent:Connect(function(tier, count)
	Audio.play("Merge")
	Popups.toast(("Merged %d time%s!"):format(count, count == 1 and "" or "s"), "reward")
end)

Net.event(N.Toast).OnClientEvent:Connect(function(text, kind)
	-- the server uses this channel to ask the client to open a panel too
	if text == "__OPEN_REBIRTH" then
		Screens.open("RebirthScreen")
		return
	end
	Popups.toast(text, kind)
end)

print("[ToiletFarm] client ready")
