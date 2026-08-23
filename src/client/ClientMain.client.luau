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
local Freecam  = require(Controllers.Freecam)

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
-- last, so its Shift+P is bound after everything that could have claimed a key
Freecam.init()
Screens.buildIconRow()
WorldFx.bindPads()
WorldFx.muteVanillaSounds()
WorldFx.bindFootsteps()
WorldFx.bindPlotSounds()
WorldFx.buildFlushHologram()
WorldFx.bindVfx()

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

-- The group join prompt is a client-only API, so the pad asks us to raise it.
-- PromptJoinAsync takes the group id alone (it is implicitly the local player) and
-- YIELDS for as long as the dialog is open, so it gets its own thread rather than
-- stalling the remote handler.
Net.event(N.PromptGroupJoin).OnClientEvent:Connect(function(groupId)
	if type(groupId) ~= "number" or groupId <= 0 then return end
	task.spawn(function()
		local GroupService = game:GetService("GroupService")
		local ok, err = pcall(function()
			GroupService:PromptJoinAsync(groupId)
		end)
		if not ok then
			warn("[ClientMain] group join prompt failed: " .. tostring(err))
			Popups.toast("Could not open the group page.", "error")
		end
	end)
end)

-- The RSVP dialog is Roblox's own and client-only, so the server tells us when to
-- raise it and we do nothing else with it. Like PromptJoinAsync it takes the id
-- alone -- it is implicitly the local player -- and YIELDS for as long as the
-- dialog is up, so it gets its own thread rather than stalling the remote handler.
-- Whether the server should have asked at all is the server's decision and it has
-- already been made and saved by the time this fires.
Net.event(N.PromptEventRsvp).OnClientEvent:Connect(function(eventId)
	if type(eventId) ~= "string" or eventId == "" then return end
	task.spawn(function()
		local SocialService = game:GetService("SocialService")
		local ok, err = pcall(function()
			-- Somebody who already said yes on the game page does not need asking.
			-- The server has spent its one prompt either way, which is the right
			-- answer: they are going, so there is nothing left to ask them.
			if SocialService:GetEventRsvpStatusAsync(eventId) ~= Enum.RsvpStatus.None then
				return
			end
			SocialService:PromptRsvpToEventAsync(eventId)
		end)
		if not ok then
			warn("[ClientMain] event RSVP prompt failed: " .. tostring(err))
		end
	end)
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
