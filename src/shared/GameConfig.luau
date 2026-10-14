--!strict
-- GameConfig.luau
-- All tunable game constants. Require this module on both server and client;
-- never hardcode these values elsewhere. (specs §11)

local GameConfig = {
	-- Round flow
	MIN_PLAYERS        = 3,      -- minimum players in lobby to start a round
	ROUND_SECONDS      = 300,    -- round timer duration in seconds (5 minutes)
	INTERMISSION_SECONDS = 3,   -- lobby countdown (starts once MIN_PLAYERS are present) before the next round

	-- Roles
	ALIEN_COUNT       = 1,      -- number of Aliens per round
	SCIENTIST_COUNT    = 1,      -- number of Scientists per round

	-- Alien mechanics
	ABDUCT_RANGE       = 5,      -- max studs (HRP-to-HRP) for a valid abduction attack
	ABDUCT_COOLDOWN    = 1,      -- seconds between Alien attacks (enforced server-side)

	-- Freeze Gun mechanics
	FREEZE_COOLDOWN    = 2.5,    -- seconds between Freeze Gun shots (enforced server-side)
	FREEZE_RANGE       = 1000,   -- Freeze Gun raycast length in studs (effectively unlimited LoS)
}

return GameConfig
