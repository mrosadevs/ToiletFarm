--!strict
-- Index — rebuilds the discovery grid from real save data.
-- The Figma import ships twelve hard-coded example cards; those are mockup only,
-- so they get cleared and replaced with 30 toilets + 8 mutations driven by state.

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.ToiletConfig)
local Format = require(Shared.Format)
local IconManifest = require(Shared.IconManifest)

local UIKit = require(script.Parent.UIKit)
local Audio = require(script.Parent.Audio)
local State = require(script.Parent.State)

local player = Players.LocalPlayer
local gui = player:WaitForChild("PlayerGui")

local Index = {}

local grid: ScrollingFrame
local header: TextLabel
local built = false

-- The grid is authored 1060 wide for four 254 cards and three 14 gaps -- 1058, a
-- two pixel margin. A ScrollingFrame then takes its scrollbar out of that same
-- width, so the fourth column had 6 pixels nowhere to go and every card in it was
-- sliced down the right-hand side. The cell width is therefore MEASURED from what
-- the frame actually leaves, rather than pasted in, and the inset keeps the cards
-- off the frame's edges so a card's border is not clipped top or right.
local CARD = Vector2.new(254, 190)
local COLUMNS = 4
local GAP = 14
local INSET = 10
local BAR = 10

local function makeCard(key: string, displayName: string, subtitle: string, rarity: string): Frame
	local card = Instance.new("Frame")
	card.Name = "Card_" .. key
	card.Size = UDim2.fromOffset(CARD.X, CARD.Y)
	card.BackgroundColor3 = Color3.fromRGB(26, 26, 30)
	card.BorderSizePixel = 0
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 14)
	corner.Parent = card
	local stroke = Instance.new("UIStroke")
	stroke.Name = "Rim"
	stroke.Thickness = 3
	stroke.Color = Color3.new(0, 0, 0)
	stroke.Parent = card

	local icon = Instance.new("ImageLabel")
	icon.Name = "Icon"
	icon.BackgroundTransparency = 1
	icon.Size = UDim2.fromOffset(126, 126)
	icon.Position = UDim2.new(0.5, 0, 0, 6)
	icon.AnchorPoint = Vector2.new(0.5, 0)
	icon.ScaleType = Enum.ScaleType.Fit
	icon.Parent = card

	local name = Instance.new("TextLabel")
	name.Name = "EntryName"
	name.BackgroundTransparency = 1
	name.Size = UDim2.new(1, -8, 0, 30)
	name.Position = UDim2.fromOffset(4, 140)
	name.Font = Enum.Font.FredokaOne
	name.TextScaled = true
	name.TextColor3 = Color3.new(1, 1, 1)
	local ns = Instance.new("UIStroke")
	ns.Thickness = 2.5; ns.Color = Color3.new(0, 0, 0); ns.Parent = name
	name.Parent = card

	local cost = Instance.new("TextLabel")
	cost.Name = "CostLabel"
	cost.BackgroundTransparency = 1
	cost.Size = UDim2.new(0, 110, 0, 28)
	cost.Position = UDim2.new(1, -116, 0, 8)
	cost.TextXAlignment = Enum.TextXAlignment.Right
	cost.Font = Enum.Font.FredokaOne
	cost.TextScaled = true
	cost.TextColor3 = Color3.fromRGB(255, 225, 120)
	local cs = Instance.new("UIStroke")
	cs.Thickness = 2.5; cs.Color = Color3.new(0, 0, 0); cs.Parent = cost
	cost.Parent = card

	card:SetAttribute("Key", key)
	card:SetAttribute("DisplayName", displayName)
	card:SetAttribute("Subtitle", subtitle)
	card:SetAttribute("Rarity", rarity)
	return card
end

local function paintCard(card: Frame, unlocked: boolean)
	local key = card:GetAttribute("Key") :: string
	local icon = card:FindFirstChild("Icon") :: ImageLabel
	local name = card:FindFirstChild("EntryName") :: TextLabel
	local cost = card:FindFirstChild("CostLabel") :: TextLabel
	local rim = card:FindFirstChild("Rim") :: UIStroke

	icon.Image = IconManifest.icon(key, unlocked)
	if unlocked then
		name.Text = card:GetAttribute("DisplayName") :: string
		cost.Text = card:GetAttribute("Subtitle") :: string
		icon.ImageColor3 = Color3.new(1, 1, 1)
		name.TextColor3 = Color3.new(1, 1, 1)
		local rarity = card:GetAttribute("Rarity") :: string
		rim.Color = Config.RARITY_COLORS[rarity] or Color3.new(0, 0, 0)
		rim.Thickness = 3
		card.BackgroundColor3 = Color3.fromRGB(34, 34, 40)
	else
		name.Text = "???"
		cost.Text = "???"
		-- The locked icons are a black silhouette with a white rim, so the card behind
		-- them has to be light enough for the silhouette to read at all.
		icon.ImageColor3 = Color3.new(1, 1, 1)
		name.TextColor3 = Color3.fromRGB(150, 150, 162)
		rim.Color = Color3.fromRGB(70, 70, 82)
		rim.Thickness = 3
		card.BackgroundColor3 = Color3.fromRGB(66, 66, 78)
	end
	card:SetAttribute("Unlocked", unlocked)
end

local function build()
	if built then return end
	built = true

	-- clear the Figma mockup cards
	for _, c in ipairs(grid:GetChildren()) do
		if c:IsA("GuiObject") then c:Destroy() end
	end

	local layout = grid:FindFirstChildOfClass("UIGridLayout")
	if not layout then
		layout = Instance.new("UIGridLayout")
		layout.Parent = grid
	end
	-- The authored offset, not AbsoluteSize: a UIScale on the container means the
	-- absolute figure is in scaled pixels while the layout works in unscaled ones.
	local frameWidth = grid.Size.X.Offset
	local usable = frameWidth - BAR - INSET * 2 - GAP * (COLUMNS - 1)
	local cellWidth = math.max(80, math.floor(usable / COLUMNS))
	layout.CellSize = UDim2.fromOffset(cellWidth, CARD.Y)
	layout.CellPadding = UDim2.fromOffset(GAP, GAP)
	layout.SortOrder = Enum.SortOrder.LayoutOrder

	for tier = 1, Config.MAX_TIER do
		local key = Config.assetId(tier)
		local card = makeCard(key, Config.displayName(tier),
			"$" .. Format.short(Config.buyCost(tier)), Config.rarityOf(tier))
		card.LayoutOrder = tier
		card.Parent = grid
	end
	for i, mut in ipairs(Config.MUTATION_ORDER) do
		local key = "MUT_" .. mut
		local card = makeCard(key, mut, ("x%s value"):format(Config.MUTATIONS[mut]), "Legendary")
		card.LayoutOrder = 100 + i
		card.Parent = grid
	end

	-- the mockup grid was a plain Frame; make it scroll now that it holds 38 cards.
	-- Measured rather than computed from a row count, so the inset is included and a
	-- change to the card count cannot leave the last row unreachable.
	grid.CanvasSize = UDim2.new()
	grid.AutomaticCanvasSize = Enum.AutomaticSize.Y
	grid.ScrollBarThickness = BAR
end

function Index.refresh()
	if not grid then return end
	build()
	local discovered = State.data.discovered or {}
	local toilets, mutations = 0, 0
	for _, card in ipairs(grid:GetChildren()) do
		if card:IsA("Frame") and card:GetAttribute("Key") then
			local key = card:GetAttribute("Key") :: string
			local unlocked = discovered[key] == true
			if unlocked then
				if key:match("^MUT_") then mutations += 1 else toilets += 1 end
			end
			if card:GetAttribute("Unlocked") ~= unlocked then
				paintCard(card, unlocked)
			end
		end
	end
	if header then
		-- the title bar is only ~1017px wide, so keep this short enough not to clip
		header.Text = ("Index   %d/%d   •   %d/%d")
			:format(toilets, Config.MAX_TIER, mutations, #Config.MUTATION_ORDER)
	end
end

function Index.init()
	local screen = gui:WaitForChild("IndexScreen") :: ScreenGui
	local panel = screen:WaitForChild("Container"):WaitForChild("IndexPanel")
	local old = panel:WaitForChild("IndexGrid")

	-- swap the mockup Frame for a ScrollingFrame in the same slot
	if old:IsA("ScrollingFrame") then
		grid = old
	else
		local sf = Instance.new("ScrollingFrame")
		sf.Name = "IndexGrid"
		sf.Size = old.Size
		sf.Position = old.Position
		sf.BackgroundTransparency = 1
		sf.BorderSizePixel = 0
		sf.ScrollBarThickness = BAR
		sf.ScrollBarImageColor3 = Color3.fromRGB(120, 120, 130)
		sf.Parent = panel
		old:Destroy()
		grid = sf
	end

	-- Keep the cards off all four edges. Without it the top row sits flush against
	-- the frame and its border is clipped by the ScrollingFrame's own bounds.
	local inset = grid:FindFirstChildOfClass("UIPadding") or Instance.new("UIPadding")
	inset.PaddingTop = UDim.new(0, INSET)
	inset.PaddingBottom = UDim.new(0, INSET)
	inset.PaddingLeft = UDim.new(0, INSET)
	inset.PaddingRight = UDim.new(0, INSET)
	inset.Parent = grid

	-- a counter line in the title bar
	local titleBar = panel:FindFirstChild("TitleBar")
	if titleBar then
		for _, d in ipairs(titleBar:GetDescendants()) do
			if d:IsA("TextLabel") then header = d break end
		end
	end

	State.onChanged(function(_, changed)
		if changed.discovered then Index.refresh() end
	end)

	-- build immediately: the first state push can land before this listener exists,
	-- which would otherwise leave the grid empty until something else changed
	Index.refresh()
end

return Index
