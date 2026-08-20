--!strict
-- Index icon asset ids, keyed by model name ("T07_CopperComode", "MUT_Gilded").

local M = {}

M.unlocked = {
	T01_PorcelainStarter = 89423066512234,
	T02_PrimitivePit     = 117462631549350,
	T03_MossyBowl        = 73059948406430,
	T04_RustyPan         = 138163523540066,
	T05_DumpsterDeluxe   = 132696738845372,
	T06_BrickThrone      = 121027882607554,
	T07_CopperComode     = 96849136228355,
	T08_SteelShrine      = 72532692538468,
	T09_PyramidToilet    = 75339966301898,
	T10_FreshFlow        = 106109417915939,
	T11_BurgerBowl       = 139196875690693,
	T12_PlumberPipe      = 81531233240680,
	T13_BogBlossom       = 87753787697938,
	T14_GoldenFlush      = 128415768833459,
	T15_CinderSeat       = 90655732712263,
	T16_VoltSeat         = 84109027190567,
	T17_ObsidianOutlet   = 85485583781014,
	T18_DiamondSeat      = 133808750535161,
	T19_CodeCube         = 87685127002841,
	T20_NeonNomad        = 99937604240578,
	T21_MicroThrone      = 124326258885110,
	T22_MegaBowl         = 112150340206164,
	T23_StarChart        = 79445771612883,
	T24_UfoToilet        = 105778578325853,
	T25_NebulaPorcelain  = 73864525199695,
	T26_QuantumQuay      = 89203514677807,
	T27_ArcaneRunestool  = 129422608216246,
	T28_EternalThrone    = 108990433739862,
	T29_VoidVoyager      = 136957932517223,
	T30_AscensionAlter   = 136951092443209,
	MUT_Bubble  = 122803687047308,
	MUT_Snow    = 107927501382413,
	MUT_Slime   = 89157614308288,
	MUT_Gilded  = 77543500135764,
	MUT_Inferno = 124605096956240,
	MUT_Shadow  = 131899335605751,
	MUT_Vortex  = 84509180293235,
	MUT_Rainbow = 99505780725496,
	PROP_StoneBowl = 117670855798753,
	DUP_PyramidAlt = 83584709024732,
}

M.locked = {
	T01_PorcelainStarter = 70822698964635,
	T02_PrimitivePit     = 77424107580926,
	T03_MossyBowl        = 139777684834853,
	T04_RustyPan         = 81843911883785,
	T05_DumpsterDeluxe   = 89915579859203,
	T06_BrickThrone      = 77386119505901,
	T07_CopperComode     = 86360322301994,
	T08_SteelShrine      = 116485769447510,
	T09_PyramidToilet    = 139380769943793,
	T10_FreshFlow        = 133510095485013,
	T11_BurgerBowl       = 109650990430190,
	T12_PlumberPipe      = 102786256796928,
	T13_BogBlossom       = 125544804543003,
	T14_GoldenFlush      = 103726174153168,
	T15_CinderSeat       = 117200983559214,
	T16_VoltSeat         = 111217820279967,
	T17_ObsidianOutlet   = 77300493016444,
	T18_DiamondSeat      = 108716410872672,
	T19_CodeCube         = 94255063207564,
	T20_NeonNomad        = 82059438128781,
	T21_MicroThrone      = 133530371099960,
	T22_MegaBowl         = 137371250627183,
	T23_StarChart        = 136977916212169,
	T24_UfoToilet        = 131252702687132,
	T25_NebulaPorcelain  = 91715950467146,
	T26_QuantumQuay      = 115956556336546,
	T27_ArcaneRunestool  = 73876668533316,
	T28_EternalThrone    = 139875419647746,
	T29_VoidVoyager      = 76256227258507,
	T30_AscensionAlter   = 111234840806494,
	MUT_Bubble  = 84235173835833,
	MUT_Snow    = 128600072850598,
	MUT_Slime   = 131988982413649,
	MUT_Gilded  = 85247090303754,
	MUT_Inferno = 138877807748632,
	MUT_Shadow  = 136900564904403,
	MUT_Vortex  = 101318815742728,
	MUT_Rainbow = 112761106427164,
	PROP_StoneBowl = 131901588659037,
	DUP_PyramidAlt = 126868471312977,
}

-- UI art already in the place
M.ui = {
	PoopBasket = "rbxassetid://79945666865035",
}

function M.icon(key: string, isUnlocked: boolean): string
	local set = isUnlocked and M.unlocked or M.locked
	local id = set[key]
	if not id then return "" end
	return "rbxassetid://" .. tostring(id)
end

return M
