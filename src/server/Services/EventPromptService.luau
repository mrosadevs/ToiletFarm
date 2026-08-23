--!strict
-- EventPromptService — asks a player, once, to RSVP to the Roblox event.
--
-- Roblox hosts the dialog itself (SocialService), so there is no UI here and
-- nothing to style: the server decides WHO is asked and WHEN, and the client does
-- nothing but raise it. The dialog is a client-only API, which is the only reason
-- a remote is involved at all — the same shape the group-join pad already uses.
--
-- Once means once. The profile records which event a player has been shown, so the
-- dialog cannot come back on a rejoin, on a server hop, or on the next session.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Net = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Net"))
local DataService = require(script.Parent.DataService)
local Analytics = require(script.Parent.AnalyticsService)

local EventPromptService = {}

-- https://www.roblox.com/events/8920116003959079575
local EVENT_ID = "8920116003959079575"

-- Four minutes in, measured from the join rather than from when the profile
-- finished loading, so a slow load does not push the dialog later and later.
local PROMPT_AFTER = 240

-- A profile that never loads is a player who is about to be kicked; there is no
-- point holding a thread open past that.
local LOAD_TIMEOUT = 60

local PromptEvent = Net.event(Net.NAMES.PromptEventRsvp)

local function considerPlayer(player: Player)
	local joinedAt = os.clock()

	local deadline = joinedAt + LOAD_TIMEOUT
	while not DataService.isLoaded(player) and os.clock() < deadline do
		task.wait(1)
	end
	local p = DataService.get(player)
	if not p or not player.Parent then return end
	if p.eventPrompt == EVENT_ID then return end

	local remaining = PROMPT_AFTER - (os.clock() - joinedAt)
	if remaining > 0 then task.wait(remaining) end
	-- everything below has to be re-checked: four minutes is long enough to leave,
	-- and long enough for the profile to have been released on the way out
	if not player.Parent then return end
	p = DataService.get(player)
	if not p or p.eventPrompt == EVENT_ID then return end

	-- Marked BEFORE the dialog is raised, and marked whatever the player does with
	-- it. "Show it once" is a promise about the dialog appearing, not about getting
	-- an answer, and a prompt that retried until somebody said yes would be the
	-- nagging this is meant to avoid.
	p.eventPrompt = EVENT_ID
	DataService.push(player, { eventPrompt = EVENT_ID })

	PromptEvent:FireClient(player, EVENT_ID)
	Analytics.custom(player, "EventPromptShown", 1)
end

function EventPromptService.init()
	Players.PlayerAdded:Connect(function(player)
		task.spawn(considerPlayer, player)
	end)
end

return EventPromptService
