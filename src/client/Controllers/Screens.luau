--!strict
-- Screens — opening and closing the Figma panels with bounce + sound, and the
-- top-bar icon row that gets you to Codes / Settings / Profile.

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local GuiService = game:GetService("GuiService")
local SocialService = game:GetService("SocialService")

local UIKit = require(script.Parent.UIKit)
local Audio = require(script.Parent.Audio)

local player = Players.LocalPlayer
local gui = player:WaitForChild("PlayerGui")

local Screens = {}
local registered: { [string]: ScreenGui } = {}
local openName: string? = nil
local openHandlers: { [string]: () -> () } = {}

function Screens.register(name: string, onOpen: (() -> ())?)
	local screen = gui:WaitForChild(name, 10) :: ScreenGui?
	if not screen then
		warn("[Screens] missing " .. name)
		return
	end
	registered[name] = screen
	screen.Enabled = false
	screen.ResetOnSpawn = false
	screen.DisplayOrder = 20
	UIKit.bindScale(screen)
	if onOpen then openHandlers[name] = onOpen end

	-- every panel's X closes it
	local close = screen:FindFirstChild("CloseButton", true)
	if close and close:IsA("GuiObject") then
		UIKit.makeInteractive(close, function() Screens.close(name) end, {
			hover = 1.0,
			press = 0.95,
			onHover = function() Audio.play("UiHover", { volume = 0.4 }) end,
		})
	end
	return screen
end

function Screens.isOpen(name: string): boolean
	return openName == name
end

function Screens.open(name: string)
	local screen = registered[name]
	if not screen then return end
	if openName and openName ~= name then Screens.close(openName, true) end
	openName = name
	local container = screen:FindFirstChild("Container")
	screen.Enabled = true
	if container and container:IsA("GuiObject") then
		-- bounce the panel, not the container's UIScale, or we fight the viewport scale
		local panel = nil
		for _, c in ipairs(container:GetChildren()) do
			if c:IsA("GuiObject") and c.Name:match("Panel") then panel = c break end
		end
		UIKit.bounceIn(panel or container, 0.6)
	end
	Audio.play("UiOpen")
	local handler = openHandlers[name]
	if handler then task.spawn(handler) end
end

function Screens.close(name: string, silent: boolean?)
	local screen = registered[name]
	if not screen or not screen.Enabled then return end
	if openName == name then openName = nil end
	local container = screen:FindFirstChild("Container")
	local panel = nil
	if container then
		for _, c in ipairs(container:GetChildren()) do
			if c:IsA("GuiObject") and c.Name:match("Panel") then panel = c break end
		end
	end
	if not silent then Audio.play("UiClose") end
	if panel then
		UIKit.bounceOut(panel, function()
			screen.Enabled = false
			panel.Visible = true
		end)
	else
		screen.Enabled = false
	end
end

function Screens.toggle(name: string)
	if Screens.isOpen(name) then Screens.close(name) else Screens.open(name) end
end

-- ── top-left icon row ─────────────────────────────────────────────────────
-- Circular buttons that continue the real Roblox top bar, picking up where its own
-- icons stop -- the row every other tycoon puts them in, rather than a second row
-- underneath at their own size.
-- Codes, Settings, Profile -- and nothing else. Index has its own button down the
-- right-hand side of the HUD, and the Shop icon only ever raised a "coming soon"
-- toast; buying cash is the + beside the balance now.
-- `invite` raises Roblox's own invite-a-friend dialog instead of one of our panels,
-- so every entry carries both fields and the shape stays uniform.
local ICONS = {
	{ name = "Codes",    screen = "RedeemCodesScreen", image = "rbxassetid://94059211188461",  invite = false },
	{ name = "Settings", screen = "SettingsScreen",    image = "rbxassetid://77358150753910",  invite = false },
	{ name = "Profile",  screen = "ProfileScreen",     image = "rbxassetid://118735441671958", invite = false },
	{ name = "Invite",   screen = "",                  image = "rbxassetid://132819889079323", invite = true  },
}

-- CanSendGameInviteAsync is a web call, so it is asked on the click that needs the
-- answer and never on a loop, and the button is latched shut while it is in flight
-- so a second click cannot stack a second request.
local invitePending = false

local function promptInvite()
	if invitePending then return end
	invitePending = true
	task.spawn(function()
		local ok, can = pcall(function()
			return SocialService:CanSendGameInviteAsync(player)
		end)
		if not ok then
			warn("[Screens] invite check failed: " .. tostring(can))
		elseif can then
			local sent, err = pcall(function()
				-- PromptMessage is the only option here that needs no Creator
				-- Dashboard setup; InviteMessageId would need a notification asset.
				local opts = Instance.new("ExperienceInviteOptions")
				opts.PromptMessage = "Come run a toilet farm with me!"
				SocialService:PromptGameInvite(player, opts)
			end)
			if not sent then warn("[Screens] invite prompt failed: " .. tostring(err)) end
		end
		invitePending = false
	end)
end

-- All three as a share of the top bar's height, because that height is what changes
-- between devices. Measured off a 1:1 screenshot of the real bar: on a 58px bar
-- Roblox draws 44px chips, 9px apart, starting 11px down. Those land on 0.76, 0.20
-- and 0.19 exactly, and stay proportional everywhere else.
--
-- ICON_TOP is why this hangs off the top edge rather than centring on the inset:
-- the inset is 58 tall but Roblox's own chips are not centred in it -- they sit
-- 11px from the top and only 3px off the bottom. Centring put us 5px high.
local ICON_SCALE = 0.76
local ICON_GAP = 0.20
local ICON_TOP = 0.19

function Screens.buildIconRow()
	local screen = Instance.new("ScreenGui")
	screen.Name = "TopIcons"
	screen.ResetOnSpawn = false
	-- The row lives INSIDE the strip the inset normally pushes everything out of,
	-- so it has to measure from the true top-left of the screen.
	screen.IgnoreGuiInset = true
	screen.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	screen.DisplayOrder = 12
	screen.Parent = gui

	local row = Instance.new("Frame")
	row.Name = "Row"
	row.BackgroundTransparency = 1
	row.AnchorPoint = Vector2.new(0, 0.5)
	row.Parent = screen

	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Horizontal
	layout.VerticalAlignment = Enum.VerticalAlignment.Center
	-- Explicit, and every button gets a LayoutOrder below. With all of them left on
	-- 0 the layout falls back to sorting by NAME, which quietly ordered the row
	-- Codes / Invite / Profile / Settings -- alphabetical, not the order declared.
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = row

	local buttons: { Frame } = {}

	for i, def in ipairs(ICONS) do
		local btn = Instance.new("Frame")
		btn.Name = def.name
		btn.LayoutOrder = i
		btn.BackgroundColor3 = Color3.fromRGB(23, 23, 26)
		btn.BackgroundTransparency = 0.1
		btn.BorderSizePixel = 0
		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(1, 0)
		corner.Parent = btn

		local img = Instance.new("ImageLabel")
		img.Name = "Icon"
		img.Size = UDim2.fromScale(1, 1)
		img.BackgroundTransparency = 1
		img.ScaleType = Enum.ScaleType.Fit
		img.Image = def.image
		local pad = Instance.new("UIPadding")
		pad.PaddingTop = UDim.new(0.17, 0); pad.PaddingBottom = UDim.new(0.17, 0)
		pad.PaddingLeft = UDim.new(0.17, 0); pad.PaddingRight = UDim.new(0.17, 0)
		pad.Parent = img
		img.Parent = btn

		btn.Parent = row
		table.insert(buttons, btn)

		UIKit.makeInteractive(btn, function()
			Audio.play("UiClick")
			if def.invite then
				promptInvite()
			else
				Screens.toggle(def.screen)
			end
		end, {
			hover = 1.15,
			onHover = function() Audio.play("UiHover", { volume = 0.4 }) end,
		})
	end

	-- TopbarInset is the slice of the top bar left OVER for us — it starts where
	-- Roblox's own run of icons ends, so Min.X is the pixel just past the shop
	-- basket and Max.X is the right edge of the screen, not the end of their icons.
	-- (Reading Max.X as "where their icons stop" puts the row off-screen right.)
	-- It moves, too: the shop icon comes and goes, the bar wraps on a phone, and it
	-- is a different height on every device. Reading it beats hard-coding an offset
	-- that is correct on one screen and wrong on all the others.
	local function relayout()
		local inset = GuiService.TopbarInset
		local h = inset.Height
		if h <= 0 then h = 36 end
		local size = math.round(h * ICON_SCALE)
		local gap = math.round(size * ICON_GAP)
		layout.Padding = UDim.new(0, gap)
		for _, b in ipairs(buttons) do
			b.Size = UDim2.fromOffset(size, size)
		end
		row.Size = UDim2.fromOffset(size * #buttons + gap * (#buttons - 1), size)
		-- lined up with the top edge of Roblox's chips, not the middle of the strip
		local top = math.round(h * ICON_TOP)
		row.Position = UDim2.fromOffset(inset.Min.X + gap, inset.Min.Y + top + size // 2)
	end

	relayout()
	GuiService:GetPropertyChangedSignal("TopbarInset"):Connect(relayout)
	return screen
end

return Screens
