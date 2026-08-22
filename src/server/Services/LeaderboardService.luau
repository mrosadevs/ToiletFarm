--!strict
-- LeaderboardService — fills the three boards standing in the middle of the hub.
--
-- The boards were authored complete: a Header carrying the title, and a Main whose
-- SurfaceGui holds a ScrollingFrame with a `Template` row (Rank / plrName / Amount).
-- Nothing ever wrote to them, so all three showed the mockup row -- "#1 name 45.4K"
-- -- forever. This binds each one by the title it was authored with rather than by
-- model name, so reordering or renaming the models in Studio cannot silently break
-- the mapping.
--
-- Scores are global and come from DataService (the only module allowed to touch
-- DataStoreService). When that comes back empty -- a brand new store, or Studio with
-- API access off -- the board falls back to the players currently in the server, so
-- it always reads as a working board rather than a blank slab.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.ToiletConfig)
local Format = require(Shared.Format)

local DataService = require(script.Parent.DataService)

local LeaderboardService = {}

local ROWS = 25
local REFRESH = 60

-- authored header title -> the board key DataService publishes under, and how the
-- number should read
local BOARDS = {
	["Networth"]     = { key = "Networth", format = function(v) return "$" .. Format.cash(v) end },
	["Total Toilets"] = { key = "Toilets",  format = function(v) return Format.short(v) end },
	["Time Played"]  = { key = "Playtime", format = function(v) return Format.duration(v) end },
}

type Board = {
	key: string,
	format: (number) -> string,
	list: ScrollingFrame,
	template: Frame,
}

local boards: { Board } = {}

local function titleOf(model: Model): string?
	-- recursive: the boards wrap Header and Main in an inner Model, so a direct-child
	-- lookup finds neither
	local header = model:FindFirstChild("Header", true)
	local label = header and header:FindFirstChild("Amount", true)
	if label and label:IsA("TextLabel") then return label.Text end
	return nil
end

local function collect()
	local hub = workspace:FindFirstChild("Hub")
	if not hub then
		warn("[LeaderboardService] no Workspace.Hub -- boards not bound")
		return
	end

	for _, model in ipairs(hub:GetChildren()) do
		if model:IsA("Model") and model.Name:lower():find("leaderboard") then
			local title = titleOf(model)
			local spec = title and BOARDS[title]
			local main = model:FindFirstChild("Main", true)
			local list = main and main:FindFirstChild("ScrollingFrame", true)
			local template = list and list:FindFirstChild("Template")

			if not spec then
				warn(("[LeaderboardService] %s has an unrecognised title %q"):format(model.Name, tostring(title)))
			elseif not (list and list:IsA("ScrollingFrame") and template and template:IsA("Frame")) then
				warn(("[LeaderboardService] %s is missing its ScrollingFrame/Template"):format(model.Name))
			else
				template.Visible = false
				-- the rows are added and removed wholesale, so let the frame measure itself
				list.AutomaticCanvasSize = Enum.AutomaticSize.Y
				list.CanvasSize = UDim2.fromOffset(0, 0)
				list.ScrollBarThickness = 6
				table.insert(boards, {
					key = spec.key,
					format = spec.format,
					list = list :: ScrollingFrame,
					template = template :: Frame,
				})
			end
		end
	end
end

-- Everyone currently in this server, so a board is never blank while the global
-- store is empty or unreachable.
local function localScores(key: string)
	local out = {}
	for _, player in ipairs(Players:GetPlayers()) do
		local p = DataService.get(player)
		if p then
			local value
			if key == "Networth" then
				value = p.cash or 0
			elseif key == "Playtime" then
				value = (p.stats and p.stats.playtime) or 0
			else
				local n = 0
				for _, t in ipairs(p.toilets or {}) do
					n += Config.MERGE_COUNT ^ ((t.tier or 1) - 1)
				end
				value = n
			end
			table.insert(out, { userId = player.UserId, name = player.Name, value = value })
		end
	end
	table.sort(out, function(a, b) return a.value > b.value end)
	return out
end

local function render(board: Board, entries)
	for _, child in ipairs(board.list:GetChildren()) do
		if child:IsA("Frame") and child ~= board.template then child:Destroy() end
	end

	for rank, entry in ipairs(entries) do
		local row = board.template:Clone()
		row.Name = ("Row%02d"):format(rank)
		row.LayoutOrder = rank
		row.Visible = true

		local rankLabel = row:FindFirstChild("Rank")
		if rankLabel and rankLabel:IsA("TextLabel") then rankLabel.Text = "#" .. rank end
		local nameLabel = row:FindFirstChild("plrName")
		if nameLabel and nameLabel:IsA("TextLabel") then nameLabel.Text = entry.name end
		local amountLabel = row:FindFirstChild("Amount")
		if amountLabel and amountLabel:IsA("TextLabel") then amountLabel.Text = board.format(entry.value) end

		row.Parent = board.list
	end
end

function LeaderboardService.refresh()
	for _, board in ipairs(boards) do
		local entries = DataService.topScores(board.key, ROWS)
		if #entries == 0 then
			entries = localScores(board.key)
		end
		render(board, entries)
	end
end

function LeaderboardService.init()
	collect()
	if #boards == 0 then return end

	task.spawn(function()
		-- one immediate pass so the boards are populated before anyone reaches the
		-- hub, then on the slow loop: these are web reads, not a per-frame job
		while true do
			local ok, err = pcall(LeaderboardService.refresh)
			if not ok then
				warn(("[LeaderboardService] refresh failed: %s"):format(tostring(err)))
			end
			task.wait(REFRESH)
		end
	end)
end

return LeaderboardService
