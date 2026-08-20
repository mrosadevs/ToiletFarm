--!strict
-- RemoteGuard — one door for every client-to-server call.
--
-- The client expresses intent; the server determines truth. A handler registered
-- here is only reached once the caller has passed the rate limit and every argument
-- has matched its declared shape, so handlers can read their arguments as given
-- rather than each re-inventing its own validation style.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Net = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Net"))
local RateLimiter = require(script.Parent.RateLimiter)

local RemoteGuard = {}

export type Validator = (value: any) -> boolean

-- ── validators ────────────────────────────────────────────────────────────
-- Length and bounds are not optional: an unbounded string or table from a client
-- is a memory-exhaustion and log-flooding vector.

function RemoteGuard.string(opts: { maxLength: number?, minLength: number? }?): Validator
	local maxLength = (opts and opts.maxLength) or 64
	local minLength = (opts and opts.minLength) or 1
	return function(value)
		return type(value) == "string" and #value >= minLength and #value <= maxLength
	end
end

function RemoteGuard.number(opts: { min: number?, max: number?, integer: boolean? }?): Validator
	local min = opts and opts.min
	local max = opts and opts.max
	local integer = opts and opts.integer
	return function(value)
		if type(value) ~= "number" then return false end
		-- NaN fails every comparison, including against itself, and inf survives
		-- bounds checks that were written for finite numbers.
		if value ~= value or value == math.huge or value == -math.huge then return false end
		if integer and value % 1 ~= 0 then return false end
		if min and value < min then return false end
		if max and value > max then return false end
		return true
	end
end

function RemoteGuard.boolean(): Validator
	return function(value)
		return type(value) == "boolean"
	end
end

-- For an argument whose legal shape genuinely depends on server state the handler
-- already holds. Still bounded: tables and functions are never accepted.
function RemoteGuard.scalar(): Validator
	return function(value)
		local t = type(value)
		if t == "string" then return #value <= 64 end
		if t == "number" then return value == value and value ~= math.huge and value ~= -math.huge end
		return t == "boolean"
	end
end

-- Wraps a validator so a missing argument is allowed but a malformed one is not.
function RemoteGuard.optional(validator: Validator): Validator
	return function(value)
		return value == nil or validator(value)
	end
end

-- ── violation reporting ───────────────────────────────────────────────────
-- Rejecting the request is the actual defence. Logging is for investigation, so it
-- is throttled: an exploiter hammering an endpoint must not turn Output into its
-- own denial of service. Nothing is ever reported back to the client, which would
-- only tell it where the edges are.
local lastReport: { [string]: number } = {}
local REPORT_INTERVAL = 10

local function report(player: Player, action: string, reason: string)
	local key = tostring(player.UserId) .. "/" .. action .. "/" .. reason
	local now = os.clock()
	if lastReport[key] and now - lastReport[key] < REPORT_INTERVAL then return end
	lastReport[key] = now
	warn(("[RemoteGuard] rejected %s from %s (%d): %s"):format(action, player.Name, player.UserId, reason))
end

export type Policy = {
	burst: number,
	perSecond: number,
	args: { Validator }?,
}

-- Register a handler for a client-to-server RemoteEvent by its Net.NAMES key.
function RemoteGuard.handle(name: string, policy: Policy, handler: (Player, ...any) -> ())
	local validators = policy.args or {}

	Net.event(name).OnServerEvent:Connect(function(player, ...)
		if not RateLimiter.consume(player, name, policy.burst, policy.perSecond) then
			report(player, name, "rate limit")
			return
		end

		local count = select("#", ...)
		if count > #validators then
			report(player, name, "too many arguments")
			return
		end

		for index, validate in ipairs(validators) do
			if not validate((select(index, ...))) then
				report(player, name, "argument " .. index)
				return
			end
		end

		handler(player, ...)
	end)
end

return RemoteGuard
