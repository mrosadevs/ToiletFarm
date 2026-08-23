--!strict
-- Net — lazily creates remotes on the server, waits for them on the client.
-- Both sides call Net.event("Name") / Net.func("Name") with no ordering worries.

local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local IS_SERVER = RunService:IsServer()
local folder = ReplicatedStorage:FindFirstChild("Remotes")
if not folder then
	if IS_SERVER then
		folder = Instance.new("Folder")
		folder.Name = "Remotes"
		folder.Parent = ReplicatedStorage
	else
		folder = ReplicatedStorage:WaitForChild("Remotes")
	end
end

local Net = {}

local function get(className: string, name: string): Instance
	local existing = folder:FindFirstChild(name)
	if existing then return existing end
	if IS_SERVER then
		local r = Instance.new(className)
		r.Name = name
		r.Parent = folder
		return r
	end
	return folder:WaitForChild(name, 30) or error("Net: remote '" .. name .. "' never appeared")
end

function Net.event(name: string): RemoteEvent
	return get("RemoteEvent", name) :: RemoteEvent
end

function Net.func(name: string): RemoteFunction
	return get("RemoteFunction", name) :: RemoteFunction
end

-- Canonical remote names, so a typo is a nil index rather than a silent dead remote.
Net.NAMES = {
	-- server -> client
	StateChanged   = "StateChanged",   -- full/partial profile state push
	PoopPickup     = "PoopPickup",     -- {amount, worldPos} for the +N popup
	CashCollected  = "CashCollected",  -- {amount, worldPos} for the coin burst
	Deposited      = "Deposited",      -- {poops, cash, multiplier}
	Discovered     = "Discovered",     -- {key, name, rarity}
	FlushMeter     = "FlushMeter",     -- {mult, nextRollAt}
	LuckyPrompt    = "LuckyPrompt",    -- {blockId, uid}
	LuckyResult    = "LuckyResult",    -- {mutation, blockId}
	TutorialStep   = "TutorialStep",   -- {index, title, subtitle, progress, goal, done}
	OfflineReport  = "OfflineReport",  -- {poops, seconds}
	Toast          = "Toast",          -- {text, kind}
	MergeResult    = "MergeResult",    -- {tier, count}
	PromptGroupJoin = "PromptGroupJoin", -- {groupId} -- the join prompt is client-only
	PromptEventRsvp = "PromptEventRsvp", -- {eventId} -- the RSVP dialog is client-only
	PlayVfx        = "PlayVfx",        -- {key, position, burst} -- built and emitted client-side

	-- client -> server
	BuyToilet      = "BuyToilet",
	Merge          = "Merge",
	Rebirth        = "Rebirth",
	Deposit        = "Deposit",
	CollectCash    = "CollectCash",
	BuyUpgrade     = "BuyUpgrade",
	OpenLucky      = "OpenLucky",
	DiscardLucky   = "DiscardLucky",
	RedeemCode     = "RedeemCode",
	SetSetting     = "SetSetting",
	ClaimOffline   = "ClaimOffline",
	RequestState   = "RequestState",
	TeleportHome   = "TeleportHome",
	BuyTokenPerk   = "BuyTokenPerk",
}

return Net
