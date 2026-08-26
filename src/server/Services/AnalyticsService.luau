--!strict
-- AnalyticsService — everything this game reports to the Creator Dashboard, in one
-- place. Roblox's own AnalyticsService is the sink, so the funnel, retention and
-- economy pages fill in without a third-party service or any HTTP.
--
-- Two rules hold this module together.
--
-- Nothing here may affect gameplay. Every call into Roblox's service is wrapped,
-- and a failure is warned about once per event and then swallowed for the life of
-- the server: a reporting outage must never be able to stop somebody buying a
-- toilet, and a broken event must not write a log line on every fire.
--
-- Nothing here may be told anything by the client. Every event is raised from the
-- server path that already decided the thing happened, from the same numbers the
-- profile is written from, so the dashboard cannot disagree with the save. There
-- is deliberately no remote and no exported way for the client to reach any of
-- this — a client that can post its own funnel steps is a client that can invent
-- an audience.

local Players = game:GetService("Players")
local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- The Roblox service, under a name that is not this module's.
local Reporter = game:GetService("AnalyticsService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.ToiletConfig)
local DataService = require(script.Parent.DataService)

local AnalyticsService = {}

-- ── names ────────────────────────────────────────────────────────────────
-- Funnel names live in one table for the same reason remote names live in
-- Net.NAMES: a typo becomes a nil index that fails at the call site instead of a
-- live event reporting under a misspelt name. A remote typo is a dead remote you
-- notice immediately; a funnel typo is a second funnel on the dashboard that looks
-- real, collects half the data, and cannot be merged with the first one after.
local FUNNELS = {
	-- how far into a single sitting people get before they leave
	Session = "Session",
	-- how far up the cost of the next rebirth they climb in that sitting
	RebirthRun = "RebirthRun",
}
AnalyticsService.FUNNELS = FUNNELS

-- The progression path the rebirth ladder reports as: one path, one level per
-- rebirth, which is the shape the dashboard's progression view is built for.
local REBIRTH_PATH = "Rebirth"

local F1 = Enum.AnalyticsCustomFieldKeys.CustomField01.Name
local F2 = Enum.AnalyticsCustomFieldKeys.CustomField02.Name
local F3 = Enum.AnalyticsCustomFieldKeys.CustomField03.Name

-- ── buckets ──────────────────────────────────────────────────────────────
-- Roblox gives an event exactly three custom fields, and each one wants a SMALL
-- set of distinct values: they are dashboard breakdowns, not a payload. So nothing
-- raw ever goes into one. Cash would be a new value on every single event and
-- would turn the breakdown into a list of numbers nobody can group by.
--
-- Fields 1 and 2 carry the same two things on every event this game raises —
-- which rebirth they are on, and how long they have played in total — so any
-- funnel can be read per progression stage and per cohort age without needing a
-- funnel per stage. Field 3 is the event's own detail, and defaults to whether
-- the player has ever paid.
local function rebirthBucket(rebirths: number): string
	-- One bucket per rebirth. REBIRTHS is a short fixed list, so this stays bounded
	-- on its own and grows only when the ladder does.
	local max = #Config.REBIRTHS
	if rebirths >= max then return ("R%d+"):format(max) end
	return ("R%d"):format(rebirths)
end

local PLAYTIME_BUCKETS = {
	{ under = 600, label = "0-10m" },
	{ under = 1800, label = "10-30m" },
	{ under = 3600, label = "30-60m" },
	{ under = 10800, label = "1-3h" },
	{ under = 36000, label = "3-10h" },
}

local function playtimeBucket(seconds: number): string
	for _, b in ipairs(PLAYTIME_BUCKETS) do
		if seconds < b.under then return b.label end
	end
	return "10h+"
end

-- ── the safe call ────────────────────────────────────────────────────────
local warned: { [string]: boolean } = {}

-- `fn` is a method on Reporter, so Reporter goes in as the first argument.
local function report(label: string, fn: any, ...)
	local ok, err = pcall(fn, Reporter, ...)
	if not ok and not warned[label] then
		warned[label] = true
		warn(
			("[Analytics] %s failed; it will not be reported again on this server: %s"):format(
				label,
				tostring(err)
			)
		)
	end
end

-- ── per-session state ────────────────────────────────────────────────────
-- Held here rather than read back out of the profile when the player leaves,
-- because DataService clears the profile on its own PlayerRemoving and connection
-- order would then decide whether the session-end event had any context left to
-- report with.
type Session = {
	id: string, -- funnel session id for the playtime funnel
	joined: number, -- os.clock() when the session began
	milestone: number, -- how many playtime milestones have been reported
	runId: string, -- funnel session id for the rebirth attempt in progress
	runLevel: number, -- which rebirth that attempt is for
	runStep: number, -- highest rebirth-run step already reported
	rebirths: number, -- mirrored from the profile for the two context fields
	playtime: number,
	cash: number, -- mirrored so a pooled flush at leave has a closing balance
	payer: boolean,
}

local sessions: { [Player]: Session } = {}

local function context(player: Player, detail: string?): { [string]: string }
	local s = sessions[player]
	local rebirths, playtime, payer = 0, 0, false
	if s then
		rebirths, playtime, payer = s.rebirths, s.playtime, s.payer
	end
	local third = detail
	if not third then
		if payer then
			third = "payer"
		else
			third = "free"
		end
	end
	return {
		[F1] = rebirthBucket(rebirths),
		[F2] = playtimeBucket(playtime),
		[F3] = third,
	}
end

-- ── the tutorial, as Roblox's onboarding funnel ──────────────────────────
-- The onboarding funnel is the one Roblox scopes to a player's LIFETIME rather
-- than to a session, which is exactly what a first-time guided sequence is: a
-- player who quits on "Deposit your Poops" and comes back tomorrow has still only
-- ever reached that step once.
--
-- Step 1 is joining, and every tutorial step is one above its own index, so the
-- dashboard reads Joined → buy → collect → deposit → cash → three → merge, and
-- the gap between any two rows is the step people are quitting on.
--
-- The step list is handed in by Main rather than required from TutorialService,
-- which already requires this module. Handed in, and not copied, so that adding a
-- tutorial step cannot leave the funnel silently reporting the old shape.
local onboardingSteps: { any } = {}

function AnalyticsService.bindTutorial(steps: { any })
	onboardingSteps = steps
end

local function onboarding(player: Player, step: number, stepName: string)
	local p = DataService.get(player)
	if not p or not p.analytics then return end
	-- A lifetime funnel means a step must be reported once, ever. The high-water
	-- mark is in the profile and not in memory precisely because it has to survive
	-- a rejoin and a server hop — in memory it would re-report every step again on
	-- every server the player touched.
	if step <= p.analytics.onboard then return end
	p.analytics.onboard = step
	DataService.push(player, { analytics = p.analytics })
	report(
		"onboarding:" .. stepName,
		Reporter.LogOnboardingFunnelStepEvent,
		player,
		step,
		stepName,
		context(player)
	)
end

-- Called by TutorialService with the index of the step just COMPLETED.
function AnalyticsService.tutorialStep(player: Player, index: number, id: string)
	onboarding(player, index + 1, id)
end

-- A profile written before this module existed carries onboard = 0 even if the
-- player finished the tutorial months ago, so reporting their next join would drop
-- a veteran into step 1 of a first-timers' funnel and quietly inflate the top of
-- it. Seed the high-water mark from the tutorial progress already in the save
-- instead, and the funnel then only ever describes people who really are new.
local function seedOnboarding(p: any)
	if p.analytics.onboard > 0 then return end
	if p.tutorial == 0 then
		-- finished it: every step, including the join, is behind them
		p.analytics.onboard = #onboardingSteps + 1
	elseif p.tutorial > 1 then
		-- mid-tutorial: the join, plus the p.tutorial - 1 steps already completed
		p.analytics.onboard = p.tutorial
	end
	-- p.tutorial == 1 with nothing recorded is a genuinely new player, so the mark
	-- stays at 0 and their join is the first thing the funnel sees
end

-- ── the rebirth run ──────────────────────────────────────────────────────
-- The question this exists to answer is "where does the grind lose people", so the
-- steps are fractions of the cost of the next rebirth rather than events.
--
-- The last two steps are the pair worth watching against each other: Affordable
-- means the cash was in hand, Rebirthed means the button was pressed. A drop
-- between those two is not a pacing problem at all — it is a player who could not
-- find the pad, or did not believe the trade was worth it.
local RUN_STEPS = {
	{ at = 0.00, step = 1, name = "RunStart" },
	{ at = 0.25, step = 2, name = "Quarter" },
	{ at = 0.50, step = 3, name = "Half" },
	{ at = 0.75, step = 4, name = "ThreeQuarter" },
	{ at = 1.00, step = 5, name = "Affordable" },
}
local REBIRTHED_STEP = 6

local function runStep(player: Player, step: number, name: string)
	local s = sessions[player]
	if not s or step <= s.runStep then return end
	s.runStep = step
	report(
		"run:" .. name,
		Reporter.LogFunnelStepEvent,
		player,
		FUNNELS.RebirthRun,
		s.runId,
		step,
		name,
		context(player)
	)
end

-- A rebirth attempt is scoped to a sitting, not to the whole run: the funnel
-- session id is regenerated on join and after every rebirth. That is the reading
-- the drop-off question wants — how far up the ladder somebody climbed before they
-- put the game down — and a run that spans three evenings correctly appears as
-- three attempts, the first two of which stopped partway.
local function startRun(player: Player, p: any)
	local s = sessions[player]
	if not s then return end
	s.runId = HttpService:GenerateGUID(false)
	s.runLevel = p.rebirths + 1
	s.runStep = 0
	if not Config.rebirthCost(p.rebirths) then return end -- maxed: no run to be on
	runStep(player, 1, "RunStart")

	-- The progression event is the opposite scope: once per level for the player's
	-- lifetime, so the dashboard's per-level completion rate is not deflated by
	-- somebody who rejoined nine times mid-grind. Its marker is persisted for the
	-- same reason the onboarding one is.
	local level = p.rebirths + 1
	if p.analytics and p.analytics.run < level then
		p.analytics.run = level
		DataService.push(player, { analytics = p.analytics })
		report(
			"progression:start",
			Reporter.LogProgressionStartEvent,
			player,
			REBIRTH_PATH,
			level,
			("Rebirth %d"):format(level),
			context(player)
		)
	end
end

-- Called by EconomyService once a rebirth has actually gone through.
function AnalyticsService.rebirthed(player: Player, level: number)
	runStep(player, REBIRTHED_STEP, "Rebirthed")
	report(
		"progression:complete",
		Reporter.LogProgressionCompleteEvent,
		player,
		REBIRTH_PATH,
		level,
		("Rebirth %d"):format(level),
		context(player)
	)
	local p = DataService.get(player)
	if p then
		local s = sessions[player]
		if s then s.rebirths = p.rebirths end
		startRun(player, p)
	end
end

-- ── economy ──────────────────────────────────────────────────────────────
-- Every currency movement worth a line on the economy page. `sku` names the thing
-- bought or the reason paid, and it is the axis the dashboard breaks a flow down
-- by, so it has to stay a short bounded set — a tier number is fine, a cash amount
-- is not.
--
-- Amounts late in this game run to 10^15 and beyond, and are reported as they are.
-- A clamp would make the chart readable and the number wrong, and the whole reason
-- to have the chart is to see the curve as it is actually being played.
local CURRENCY_CASH = "Cash"
local CURRENCY_TOKENS = "FlushTokens"

local function economy(
	player: Player,
	flow: Enum.AnalyticsEconomyFlowType,
	currency: string,
	amount: number,
	ending: number,
	transaction: Enum.AnalyticsEconomyTransactionType,
	sku: string
)
	if amount <= 0 then return end
	report(
		"economy:" .. sku,
		Reporter.LogEconomyEvent,
		player,
		flow,
		currency,
		amount,
		ending,
		transaction.Name,
		sku,
		context(player)
	)
end

function AnalyticsService.cashEarned(
	player: Player,
	amount: number,
	ending: number,
	transaction: Enum.AnalyticsEconomyTransactionType,
	sku: string
)
	economy(player, Enum.AnalyticsEconomyFlowType.Source, CURRENCY_CASH, amount, ending, transaction, sku)
end

function AnalyticsService.cashSpent(
	player: Player,
	amount: number,
	ending: number,
	transaction: Enum.AnalyticsEconomyTransactionType,
	sku: string
)
	economy(player, Enum.AnalyticsEconomyFlowType.Sink, CURRENCY_CASH, amount, ending, transaction, sku)
end

function AnalyticsService.tokensEarned(player: Player, amount: number, ending: number, sku: string)
	economy(
		player,
		Enum.AnalyticsEconomyFlowType.Source,
		CURRENCY_TOKENS,
		amount,
		ending,
		Enum.AnalyticsEconomyTransactionType.Gameplay,
		sku
	)
end

function AnalyticsService.tokensSpent(player: Player, amount: number, ending: number, sku: string)
	economy(
		player,
		Enum.AnalyticsEconomyFlowType.Sink,
		CURRENCY_TOKENS,
		amount,
		ending,
		Enum.AnalyticsEconomyTransactionType.Shop,
		sku
	)
end

-- ── pooled cash ──────────────────────────────────────────────────────────
-- Two cash paths fire far too often to report one event each.
--
-- Auto Collect Cash calls collectCash every two seconds, so a pass owner would
-- post an economy event every two seconds for their whole session. And the bulk
-- Buy pad calls ToiletService.buy up to forty-one times for ONE press, merging
-- between each, so a single press would post forty-one separate purchases.
--
-- Both accumulate here per sku and flush once a tick as a single event. The total
-- and the closing balance come out identical to reporting each one; only the row
-- count changes, and forty rows for one button press was never the reading
-- anybody wanted.
local pooledEarn: { [Player]: { [string]: number } } = {}
local pooledSpend: { [Player]: { [string]: number } } = {}

local function pool(into: { [Player]: { [string]: number } }, player: Player, sku: string, amount: number)
	if amount <= 0 then return end
	local byPlayer = into[player]
	if not byPlayer then
		byPlayer = {}
		into[player] = byPlayer
	end
	byPlayer[sku] = (byPlayer[sku] or 0) + amount
end

-- Earned by selling poop, the only pooled source, hence Gameplay on the flush.
function AnalyticsService.cashEarnedPooled(player: Player, amount: number, sku: string)
	pool(pooledEarn, player, sku, amount)
end

-- Spent on toilets, the only pooled sink, hence Shop on the flush.
function AnalyticsService.cashSpentPooled(player: Player, amount: number, sku: string)
	pool(pooledSpend, player, sku, amount)
end

-- `ending` is passed in rather than read from the profile, because the flush on
-- the way out cannot count on there being a profile left to read: DataService
-- clears it on its own PlayerRemoving, which is connected first and only yields
-- part way through. The session's mirror of the balance is at most one tick old,
-- which is a fair closing figure and always better than dropping the event.
local function flushPools(player: Player, ending: number)
	local earn = pooledEarn[player]
	if earn then
		pooledEarn[player] = nil
		for sku, amount in pairs(earn) do
			economy(
				player,
				Enum.AnalyticsEconomyFlowType.Source,
				CURRENCY_CASH,
				amount,
				ending,
				Enum.AnalyticsEconomyTransactionType.Gameplay,
				sku
			)
		end
	end
	local spend = pooledSpend[player]
	if spend then
		pooledSpend[player] = nil
		for sku, amount in pairs(spend) do
			economy(
				player,
				Enum.AnalyticsEconomyFlowType.Sink,
				CURRENCY_CASH,
				amount,
				ending,
				Enum.AnalyticsEconomyTransactionType.Shop,
				sku
			)
		end
	end
end

-- ── Robux ────────────────────────────────────────────────────────────────
-- Raised from the receipt path only, once the grant is durable — the same moment
-- ProcessReceipt is allowed to answer PurchaseGranted. Reporting at the prompt
-- instead would count purchases that were never paid for.
function AnalyticsService.robuxSpent(player: Player, productName: string, robux: number)
	local s = sessions[player]
	if s then s.payer = true end
	report(
		"robux",
		Reporter.LogEconomyEvent,
		player,
		Enum.AnalyticsEconomyFlowType.Sink,
		"Robux",
		robux,
		0,
		Enum.AnalyticsEconomyTransactionType.IAP.Name,
		productName,
		context(player, productName)
	)
end

-- Gamepasses do not go through ProcessReceipt, so their purchase is reported from
-- the prompt-finished signal instead. Roblox only raises that with purchased=true
-- after the sale has gone through, so it is the same guarantee by a different door.
function AnalyticsService.passBought(player: Player, passName: string, robux: number)
	AnalyticsService.robuxSpent(player, "pass_" .. passName, robux)
end

-- ── custom events ────────────────────────────────────────────────────────
-- Roblox caps how many distinct custom event names an experience may have, so
-- these stay few, and every one of them is something somebody would actually go
-- looking for. `detail` lands in field 3 and is under the same bounded-set rule as
-- everything else here.
function AnalyticsService.custom(player: Player, name: string, value: number?, detail: string?)
	report("custom:" .. name, Reporter.LogCustomEvent, player, name, value or 1, context(player, detail))
end

-- ── the tick ─────────────────────────────────────────────────────────────
-- One loop drives both time-based funnels. Five seconds is far finer than either
-- needs and costs a handful of comparisons per player; the alternative was
-- touching every site that moves cash, which is most of EconomyService.
local TICK = 5
local SESSION_MINUTES = { 1, 5, 10, 20, 30, 60 }

local function updateSession(player: Player, s: Session)
	local minutes = (os.clock() - s.joined) / 60
	while s.milestone < #SESSION_MINUTES and minutes >= SESSION_MINUTES[s.milestone + 1] do
		s.milestone += 1
		local mark = SESSION_MINUTES[s.milestone]
		report(
			"session:" .. tostring(mark),
			Reporter.LogFunnelStepEvent,
			player,
			FUNNELS.Session,
			s.id,
			s.milestone,
			("Min%02d"):format(mark),
			context(player)
		)
	end
end

local function updateRun(player: Player, s: Session, p: any)
	local cost = Config.rebirthCost(p.rebirths)
	if not cost then return end -- at max rebirth there is no next one to climb to
	if s.runLevel ~= p.rebirths + 1 then
		-- The level moved without coming through rebirthed(). Re-anchor rather than
		-- go on reporting steps against the wrong cost.
		startRun(player, p)
		return
	end
	-- Every gate below the ratio is reported, not just the highest one. A funnel
	-- step whose predecessors are missing is orphaned on the dashboard, so somebody
	-- who jumps from a tenth of the cost to all of it inside one tick — a cash pack,
	-- a code, an offline claim — still lands as a complete walk up the funnel.
	local ratio = p.cash / cost
	for _, gate in ipairs(RUN_STEPS) do
		if ratio >= gate.at then runStep(player, gate.step, gate.name) end
	end
end

-- ── lifecycle ────────────────────────────────────────────────────────────
function AnalyticsService.init()
	Players.PlayerAdded:Connect(function(player)
		-- DataService loads the profile on its own PlayerAdded, connected first
		local deadline = os.clock() + 15
		while not DataService.isLoaded(player) and os.clock() < deadline do
			task.wait(0.2)
		end
		local p = DataService.get(player)
		if not p or not player.Parent then return end
		p.analytics = p.analytics or { onboard = 0, run = 0 }

		-- Read once, here, and never in the tick: PassService.has can make a web call
		-- on a cache miss, and a yield inside the loop would stall every other
		-- player's funnel behind one ownership check. By this point the join flow has
		-- already warmed that cache.
		local payer = false
		for _, has in pairs(DataService.ownedPasses(player)) do
			if has then
				payer = true
				break
			end
		end

		sessions[player] = {
			id = HttpService:GenerateGUID(false),
			joined = os.clock(),
			milestone = 0,
			runId = "",
			runLevel = -1,
			runStep = 0,
			rebirths = p.rebirths,
			playtime = (p.stats and p.stats.playtime) or 0,
			cash = p.cash,
			payer = payer,
		}

		seedOnboarding(p)
		onboarding(player, 1, "Joined")
		startRun(player, p)
	end)

	Players.PlayerRemoving:Connect(function(player)
		-- Flush before the tables are dropped, or up to a tick of real income and
		-- spending disappears every time somebody leaves — once per player per
		-- session, so it would be a visible hole in the economy page.
		local s = sessions[player]
		local ending = 0
		if s then ending = s.cash end
		flushPools(player, ending)
		pooledEarn[player] = nil
		pooledSpend[player] = nil

		if s then
			-- In minutes, because that is the unit the question gets asked in. The
			-- funnel above says which milestones a session passed; this says where
			-- between two of them it actually ended.
			AnalyticsService.custom(player, "SessionEnd", math.floor((os.clock() - s.joined) / 60))
			sessions[player] = nil
		end
	end)

	task.spawn(function()
		while true do
			task.wait(TICK)
			for player, s in pairs(sessions) do
				local p = DataService.get(player)
				if p then
					s.rebirths = p.rebirths
					s.playtime = (p.stats and p.stats.playtime) or 0
					s.cash = p.cash
					flushPools(player, p.cash)
					updateSession(player, s)
					updateRun(player, s, p)
				end
			end
		end
	end)
end

return AnalyticsService
