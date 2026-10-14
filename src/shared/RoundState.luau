--!strict
-- RoundState.luau
-- Shared type definitions for per-player and per-round state.
-- Side-effect free — no service calls, no mutation. (specs §2, §3)

local GameEnums = require(script.Parent.GameEnums)

-- Re-export enum types so consumers only need to require RoundState.
export type Role        = GameEnums.Role
export type RoundPhase  = GameEnums.RoundPhase
export type PlayerState = GameEnums.PlayerState

-- What PlayerRegistry stores for each player in the current round.
export type ParticipantRecord = {
	player: Player,
	role: Role,
	state: PlayerState,
}

-- A read-only snapshot of the current round, broadcast or queried.
export type RoundSnapshot = {
	phase: RoundPhase,
	endTime: number?,      -- workspace:GetServerTimeNow() timestamp when the round timer expires; nil outside Active phase
	roster: { Player },    -- fixed at Assigning; disconnected players removed (specs §3.3)
}

-- Result sent to clients at round end via RoundResult.
export type RoundOutcome = "AlienWin" | "HumanWin" | "Draw"

local RoundState = {}

RoundState.Outcome = {
	AlienWin = "AlienWin" :: RoundOutcome,
	HumanWin = "HumanWin" :: RoundOutcome,
	Draw     = "Draw"     :: RoundOutcome,
}

return RoundState
