--!strict
-- Screens — opening and closing the Figma panels with bounce + sound, and the
-- top-left icon row that gets you to Profile / Settings / Codes / Shop.

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")

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
-- Circular buttons in the Roblox top-bar style, sitting under the real top bar.
-- Codes, Settings, Profile -- and nothing else. Index has its own button down the
-- right-hand side of the HUD, and the Shop icon only ever raised a "coming soon"
-- toast; buying cash is the + beside the balance now.
local ICONS = {
	{ name = "Codes",    screen = "RedeemCodesScreen", icon = "", color = Color3.fromRGB(240, 170, 60),  glyph = "🏷" },
	{ name = "Settings", screen = "SettingsScreen",    icon = "", color = Color3.fromRGB(120, 130, 150), glyph = "⚙" },
	{ name = "Profile",  screen = "ProfileScreen",     icon = "", color = Color3.fromRGB(90, 150, 240),  glyph = "👤" },
}

function Screens.buildIconRow()
	local screen = Instance.new("ScreenGui")
	screen.Name = "TopIcons"
	screen.ResetOnSpawn = false
	screen.IgnoreGuiInset = false
	screen.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	screen.DisplayOrder = 12
	screen.Parent = gui

	local row = Instance.new("Frame")
	row.Name = "Row"
	row.BackgroundTransparency = 1
	row.Position = UDim2.new(0, 12, 0, 8)
	row.Size = UDim2.new(0, 400, 0, 52)
	row.Parent = screen

	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Horizontal
	layout.Padding = UDim.new(0, 8)
	layout.VerticalAlignment = Enum.VerticalAlignment.Center
	layout.Parent = row

	for _, def in ipairs(ICONS) do
		local btn = Instance.new("Frame")
		btn.Name = def.name
		btn.Size = UDim2.fromOffset(48, 48)
		btn.BackgroundColor3 = Color3.fromRGB(28, 28, 32)
		btn.BorderSizePixel = 0
		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(1, 0)
		corner.Parent = btn
		local stroke = Instance.new("UIStroke")
		stroke.Thickness = 2
		stroke.Color = def.color
		stroke.Transparency = 0.25
		stroke.Parent = btn

		local glyph = Instance.new("TextLabel")
		glyph.Name = "Glyph"
		glyph.Size = UDim2.fromScale(1, 1)
		glyph.BackgroundTransparency = 1
		glyph.Font = Enum.Font.FredokaOne
		glyph.TextScaled = true
		glyph.TextColor3 = Color3.new(1, 1, 1)
		glyph.Text = def.glyph or "✦"
		local pad = Instance.new("UIPadding")
		pad.PaddingTop = UDim.new(0, 9); pad.PaddingBottom = UDim.new(0, 9)
		pad.PaddingLeft = UDim.new(0, 9); pad.PaddingRight = UDim.new(0, 9)
		pad.Parent = glyph
		glyph.Parent = btn

		btn.Parent = row

		UIKit.makeInteractive(btn, function()
			Audio.play("UiClick")
			Screens.toggle(def.screen)
		end, {
			hover = 1.15,
			onHover = function() Audio.play("UiHover", { volume = 0.4 }) end,
		})
	end
	return screen
end

return Screens
