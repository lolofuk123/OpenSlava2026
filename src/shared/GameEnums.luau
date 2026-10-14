--!strict
-- GameEnums.luau
-- Shared enum tables for Role, RoundPhase, and PlayerState.
-- Side-effect free — safe to require on both server and client. (specs §2, §3)

export type Role        = "Alien" | "Scientist" | "Human" | "None"
export type RoundPhase  = "Lobby" | "Assigning" | "Teleporting" | "Active" | "Ending" | "Intermission"
export type PlayerState = "Lobby" | "Alive" | "Spectator"

local GameEnums = {}

GameEnums.Role = {
	Alien     = "Alien"     :: Role,
	Scientist = "Scientist" :: Role,
	Human     = "Human"     :: Role,
	None      = "None"      :: Role,
}

GameEnums.RoundPhase = {
	Lobby        = "Lobby"        :: RoundPhase,
	Assigning    = "Assigning"    :: RoundPhase,
	Teleporting  = "Teleporting"  :: RoundPhase,
	Active       = "Active"       :: RoundPhase,
	Ending       = "Ending"       :: RoundPhase,
	Intermission = "Intermission" :: RoundPhase,
}

GameEnums.PlayerState = {
	Lobby     = "Lobby"     :: PlayerState,
	Alive     = "Alive"     :: PlayerState,
	Spectator = "Spectator" :: PlayerState,
}

return GameEnums
