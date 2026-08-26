--!strict
-- Tutorial — the top-centre step banner and the beam pointing at the next target.
-- Every completed step fires confetti + the hooray sting.

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Net = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Net"))

local UIKit = require(script.Parent.UIKit)
local Popups = require(script.Parent.Popups)

local player = Players.LocalPlayer
local gui = player:WaitForChild("PlayerGui")

local Tutorial = {}

local screen: ScreenGui
local title: TextLabel
local subtitle: TextLabel
local progress: TextLabel
local marker: Part? = nil

local function build()
	screen = Instance.new("ScreenGui")
	screen.Name = "TutorialHud"
	screen.ResetOnSpawn = false
	screen.IgnoreGuiInset = true
	screen.DisplayOrder = 15
	screen.Enabled = false
	screen.Parent = gui

	local container = Instance.new("Frame")
	container.Name = "Container"
	container.AnchorPoint = Vector2.new(0.5, 0.5)
	container.Position = UDim2.fromScale(0.5, 0.5)
	container.Size = UDim2.fromOffset(1920, 1080)
	container.BackgroundTransparency = 1
	container.Parent = screen
	UIKit.bindScale(screen)

	title = Popups.outlined("Tutorial", 56, Color3.fromRGB(90, 200, 255))
	title.Size = UDim2.fromOffset(1920, 70)
	title.Position = UDim2.fromOffset(0, 96)
	title.Parent = container

	subtitle = Popups.outlined("", 52, Color3.new(1, 1, 1))
	subtitle.Size = UDim2.fromOffset(1920, 66)
	subtitle.Position = UDim2.fromOffset(0, 166)
	subtitle.Parent = container

	progress = Popups.outlined("", 44, Color3.fromRGB(230, 230, 240))
	progress.Size = UDim2.fromOffset(1920, 56)
	progress.Position = UDim2.fromOffset(0, 230)
	progress.Parent = container
end

-- a bobbing beacon over the pad the player should walk to
local function setMarker(pos: Vector3?)
	if marker then
		marker:Destroy()
		marker = nil
	end
	if not pos then return end
	local p = Instance.new("Part")
	p.Name = "TutorialMarker"
	p.Size = Vector3.new(3, 3, 3)
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.Transparency = 1
	p.CFrame = CFrame.new(pos)
	local bb = Instance.new("BillboardGui")
	bb.Size = UDim2.fromScale(5, 5)
	bb.AlwaysOnTop = true
	bb.StudsOffsetWorldSpace = Vector3.new(0, 6, 0)
	local arrow = Instance.new("TextLabel")
	arrow.Size = UDim2.fromScale(1, 1)
	arrow.BackgroundTransparency = 1
	arrow.Font = Enum.Font.FredokaOne
	arrow.TextScaled = true
	arrow.Text = "▼"
	arrow.TextColor3 = Color3.fromRGB(255, 220, 60)
	local s = Instance.new("UIStroke")
	s.Thickness = 3
	s.Color = Color3.new(0, 0, 0)
	s.Parent = arrow
	arrow.Parent = bb
	bb.Parent = p
	p.Parent = workspace
	marker = p

	-- A run of chevrons along the ground from the player to the target, rather than
	-- a beam: it reads as a path to walk instead of a laser pointing at something.
	-- Each chevron is two thin bars in a ">" and the whole run scrolls forward.
	local ARROWS = 14
	local ARROW_COLOR = Color3.fromRGB(255, 225, 70)

	local trail = Instance.new("Folder")
	trail.Name = "TutorialTrail"
	trail.Parent = workspace

	local chevrons: { Model } = {}
	for _ = 1, ARROWS do
		local m = Instance.new("Model")
		for _ = 1, 2 do
			local bar = Instance.new("Part")
			bar.Size = Vector3.new(1.9, 0.12, 0.5)
			bar.Anchored = true
			bar.CanCollide = false
			bar.CanQuery = false
			bar.CanTouch = false
			bar.CastShadow = false
			bar.Material = Enum.Material.Neon
			bar.Color = ARROW_COLOR
			bar.Parent = m
		end
		m.Parent = trail
		table.insert(chevrons, m)
	end

	task.spawn(function()
		local t0 = os.clock()
		local rayParams = RaycastParams.new()
		rayParams.FilterType = Enum.RaycastFilterType.Exclude
		rayParams.FilterDescendantsInstances = { trail, p }

		while p.Parent do
			local t = os.clock() - t0
			bb.StudsOffsetWorldSpace = Vector3.new(0, 6 + math.sin(t * 3) * 0.8, 0)

			local char = player.Character
			local hrp = char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
			if hrp then
				rayParams.FilterDescendantsInstances = { trail, p, char }
				local from = hrp.Position
				local to = pos
				local flat = Vector3.new(to.X - from.X, 0, to.Z - from.Z)
				local dist = flat.Magnitude
				local dir = dist > 0.01 and flat.Unit or Vector3.zAxis

				-- start clear of the player's own feet and stop short of the pad
				local startGap, endGap = 4, 2.5
				local usable = math.max(0, dist - startGap - endGap)
				local scroll = (t * 0.55) % 1

				for i, m in ipairs(chevrons) do
					if usable < 1 then
						for _, b in ipairs(m:GetChildren()) do
							(b :: BasePart).Transparency = 1
						end
					else
						local f = ((i - 1 + scroll) / ARROWS)
						local along = startGap + f * usable
						local at = from + dir * along

						-- sit on whatever surface is under that point
						local hit =
							workspace:Raycast(at + Vector3.new(0, 12, 0), Vector3.new(0, -60, 0), rayParams)
						local y = hit and hit.Position.Y + 0.12 or from.Y
						local base =
							CFrame.lookAt(Vector3.new(at.X, y, at.Z), Vector3.new(at.X, y, at.Z) + dir)

						-- fade in at the near end and out at the far end
						local fade = math.clamp(math.min(f, 1 - f) * 5, 0, 1)
						local bars = m:GetChildren()
						if bars[1] then
							(bars[1] :: BasePart).CFrame = base
								* CFrame.new(-0.62, 0, 0)
								* CFrame.Angles(0, math.rad(38), 0);
							(bars[1] :: BasePart).Transparency = 1 - 0.75 * fade
						end
						if bars[2] then
							(bars[2] :: BasePart).CFrame = base
								* CFrame.new(0.62, 0, 0)
								* CFrame.Angles(0, math.rad(-38), 0);
							(bars[2] :: BasePart).Transparency = 1 - 0.75 * fade
						end
					end
				end
			end
			task.wait()
		end
		trail:Destroy()
	end)
end

function Tutorial.init()
	build()
	Net.event(Net.NAMES.TutorialStep).OnClientEvent:Connect(function(payload)
		if payload.completed then
			-- celebrate the step that just finished
			-- the "hooray" sting plays for tutorial steps only
			Popups.confettiBurst(true)
			return
		end
		if payload.finished then
			screen.Enabled = false
			setMarker(nil)
			return
		end
		screen.Enabled = true
		subtitle.Text = payload.title or ""
		if payload.goal and payload.goal > 1 then
			progress.Text = ("%d/%d"):format(math.min(payload.progress or 0, payload.goal), payload.goal)
		else
			progress.Text = ""
		end
		UIKit.pop(subtitle, 1.1)
		setMarker(payload.targetPos)
	end)
end

return Tutorial
