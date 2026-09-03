--!strict
-- TutorialService — the guided opening, mirroring the reference game's step list.
-- Each completed step fires confetti + the "hooray" sting on the client.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Net = require(Shared.Net)
local Config = require(Shared.ToiletConfig)
local DataService = require(script.Parent.DataService)
local PlotService = require(script.Parent.PlotService)
local Analytics = require(script.Parent.AnalyticsService)

local StepEvent = Net.event(Net.NAMES.TutorialStep)

local TutorialService = {}

-- `target` names the pad the arrow trail should point at
TutorialService.STEPS = {
	{
		id = "buy",
		title = "Buy your first toilet!",
		goal = 1,
		target = "BuyButton",
		targetName = "BuyButton_1",
	},
	-- derived from the count scale, so turning that up cannot leave the tutorial
	-- asking for a target the first dropping already clears
	{
		id = "collect",
		title = ("Collect %d Poops"):format(5 * Config.POOP_COUNT_SCALE),
		goal = 5 * Config.POOP_COUNT_SCALE,
		target = nil,
	},
	{ id = "deposit", title = "Deposit your Poops", goal = 1, target = "DepositPad" },
	{ id = "cash", title = "Collect your Cash!", goal = 1, target = "CollectCashPad" },
	-- Goal and the opening stake come off the same constant: Config.startingCash()
	-- is exactly what this many Tier 1 toilets cost, so this step can never ask for
	-- more toilets than a fresh profile can pay for.
	{
		id = "three",
		title = ("Get %d Toilets"):format(Config.TUTORIAL_TOILETS),
		goal = Config.TUTORIAL_TOILETS,
		target = "BuyButton",
		targetName = "BuyButton_1",
	},
	{ id = "merge", title = "Merge your Toilets!", goal = 1, target = "MergePad" },
}

-- progress within the current step, runtime only
local progress: { [Player]: number } = {}

function TutorialService.current(player: Player)
	local p = DataService.get(player)
	if not p or p.tutorial == 0 then return nil end
	return TutorialService.STEPS[p.tutorial]
end

function TutorialService.push(player: Player)
	local p = DataService.get(player)
	if not p then return end
	local step = TutorialService.current(player)
	if not step then
		StepEvent:FireClient(player, { finished = true })
		return
	end
	local targetPos
	if step.target then
		local plot = PlotService.plotFor(player)
		local pad
		-- padOf returns whichever pad of that kind comes first, which for BuyButton
		-- could be the $250 or $1,000 one. Prefer an exact model name when given.
		if plot and step.targetName then pad = plot:FindFirstChild(step.targetName, true) end
		if not pad and plot then pad = PlotService.padOf(plot, step.target) end
		if pad then
			local anchor = pad.PrimaryPart
				or pad:FindFirstChild("Plate")
				or pad:FindFirstChildWhichIsA("BasePart", true)
			if anchor then targetPos = anchor.Position end
		end
	end
	StepEvent:FireClient(player, {
		index = p.tutorial,
		id = step.id,
		title = step.title,
		progress = progress[player] or 0,
		goal = step.goal,
		targetPos = targetPos,
		finished = false,
	})
end

-- Called from the gameplay services. `amount` defaults to 1.
function TutorialService.notify(player: Player, id: string, amount: number?)
	local p = DataService.get(player)
	if not p or p.tutorial == 0 then return end
	local step = TutorialService.STEPS[p.tutorial]
	if not step or step.id ~= id then return end

	progress[player] = (progress[player] or 0) + (amount or 1)
	if progress[player] >= step.goal then
		progress[player] = 0
		-- captured before the increment: this is the step that was just finished,
		-- and it is what the onboarding funnel numbers itself from
		local completed = p.tutorial
		p.tutorial += 1
		if p.tutorial > #TutorialService.STEPS then p.tutorial = 0 end
		StepEvent:FireClient(player, { completed = step.id, index = p.tutorial })
		DataService.push(player, { tutorial = p.tutorial })
		Analytics.tutorialStep(player, completed, step.id)
		task.wait(0.8)
	end
	TutorialService.push(player)
end

-- "Get 3 Toilets" is a state check, not a counter, so it re-evaluates on any change
function TutorialService.syncCounts(player: Player)
	local p = DataService.get(player)
	if not p or p.tutorial == 0 then return end
	local step = TutorialService.STEPS[p.tutorial]
	if step and step.id == "three" then
		progress[player] = #p.toilets
		if #p.toilets >= step.goal then
			TutorialService.notify(player, "three", 0)
		else
			TutorialService.push(player)
		end
	end
end

function TutorialService.reset(player: Player)
	progress[player] = nil
end

return TutorialService
