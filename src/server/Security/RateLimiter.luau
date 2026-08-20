--!strict
-- RateLimiter — per-player, per-action token buckets.
--
-- Every endpoint is assumed to be called as fast as the network allows, so the
-- policy is per action rather than one global throttle: dragging a settings slider
-- and redeeming a code have nothing sensible in common.

local Players = game:GetService("Players")

local RateLimiter = {}

type Bucket = { tokens: number, last: number }

local buckets: { [Player]: { [string]: Bucket } } = {}

-- Returns true when the call is allowed, false when the bucket is empty.
-- `burst` is how many calls may arrive at once; `perSecond` is the refill rate.
function RateLimiter.consume(player: Player, action: string, burst: number, perSecond: number): boolean
	local byPlayer = buckets[player]
	if not byPlayer then
		byPlayer = {}
		buckets[player] = byPlayer
	end

	local now = os.clock()
	local bucket = byPlayer[action]
	if not bucket then
		bucket = { tokens = burst, last = now }
		byPlayer[action] = bucket
	end

	-- refill for the time that has passed, never above the burst ceiling
	local elapsed = now - bucket.last
	if elapsed > 0 then
		bucket.tokens = math.min(burst, bucket.tokens + elapsed * perSecond)
		bucket.last = now
	end

	if bucket.tokens < 1 then return false end
	bucket.tokens -= 1
	return true
end

function RateLimiter.clear(player: Player)
	buckets[player] = nil
end

Players.PlayerRemoving:Connect(RateLimiter.clear)

return RateLimiter
