--!strict
local Format = {}

local SUFFIXES = { "", "K", "M", "B", "T", "Qa", "Qi", "Sx", "Sp", "Oc", "No", "Dc" }

-- 1234567 -> "1.23M".  Under 1000 stays whole so early-game numbers read exactly.
function Format.short(n: number): string
	if n ~= n or n == math.huge then return "∞" end
	local neg = n < 0
	n = math.abs(n)
	local out
	if n < 1000 then
		out = tostring(math.floor(n))
	else
		local idx = math.min(math.floor(math.log(n, 1000)), #SUFFIXES - 1)
		local scaled = n / (1000 ^ idx)
		-- 3 significant figures, trailing zeros trimmed
		local decimals = scaled < 10 and 2 or (scaled < 100 and 1 or 0)
		out = string.format("%." .. decimals .. "f", scaled)
		if decimals > 0 then
			out = out:gsub("%.?0+$", "")
		end
		out ..= SUFFIXES[idx + 1]
	end
	return (neg and "-" or "") .. out
end

-- 1234567 -> "1,234,567"
function Format.comma(n: number): string
	local s = tostring(math.floor(math.abs(n)))
	local k
	repeat
		s, k = s:gsub("^(%-?%d+)(%d%d%d)", "%1,%2")
	until k == 0
	return (n < 0 and "-" or "") .. s
end

-- Under 100k show it in full with commas, above that abbreviate.
-- Chicken Farm does this and it makes the early game feel more precise.
function Format.cash(n: number): string
	if math.abs(n) < 100000 then return Format.comma(n) end
	return Format.short(n)
end

-- 22320 -> "6h 12m"
function Format.duration(seconds: number): string
	seconds = math.max(0, math.floor(seconds))
	local d = seconds // 86400
	local h = (seconds % 86400) // 3600
	local m = (seconds % 3600) // 60
	local s = seconds % 60
	if d > 0 then return string.format("%dd %dh", d, h) end
	if h > 0 then return string.format("%dh %dm", h, m) end
	if m > 0 then return string.format("%dm %ds", m, s) end
	return string.format("%ds", s)
end

return Format
