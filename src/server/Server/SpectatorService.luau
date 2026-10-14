--!strict
-- SpectatorService.luau  (ModuleScript, ServerScriptService/Server)
-- Spectator enrollment. (specs §8, plan 6.1 / 6.2)
--
-- A player enters Spectator when abducted, eliminated, or when joining mid-round.
-- On entry the server removes their character from play — with no body in the
-- world there is nothing to move, interact with, or target, which satisfies the
-- "input disabled server-side" requirement without touching controls. Their view
-- is driven entirely client-side by SpectatorController (camera cycling).
--
-- The alive-player list used for that camera cycling is served via the
-- SpectatorTargets RemoteFunction (plan 6.2).

local ReplicatedStorage   = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Shared    = ReplicatedStorage:WaitForChild("Shared")
local GameEnums = require(Shared:WaitForChild("GameEnums"))

local Server         = ServerScriptService:WaitForChild("Server")
local PlayerRegistry = require(Server:WaitForChild("PlayerRegistry"))

local Remotes          = ReplicatedStorage:WaitForChild("Remotes")
local SpectatorTargets = Remotes:WaitForChild("SpectatorTargets") :: RemoteFunction

local State = GameEnums.PlayerState

local SpectatorService = {}

-- Handlers run (in registration order) just BEFORE a player is removed from play,
-- while their character is still intact. FreezeService registers one to drop the
-- gun if the eliminated player was holding it. (plan 5.5)
local beforeEnterHandlers: { (player: Player) -> () } = {}

function SpectatorService.onBeforeEnter(handler: (player: Player) -> ())
	table.insert(beforeEnterHandlers, handler)
end

-- Move a player into Spectator: mark their state and remove their character from
-- play. Removing (rather than freezing) the character guarantees they cannot
-- move, interact, or be targeted by a raycast/range check. Safe to call when the
-- player has no character yet (mid-round joiner) — it just sets the state.
function SpectatorService.enter(player: Player)
	-- Notify listeners while the character still exists (position/tools readable).
	for _, handler in beforeEnterHandlers do
		handler(player)
	end
	PlayerRegistry.setState(player, State.Spectator)
	local character = player.Character
	if character then
		player.Character = nil
		character:Destroy()
	end
end

-- Returns true when the player is currently a Spectator.
-- Intended as a guard for AlienService/FreezeService (Phase 4/5): calling this
-- before any game-affecting logic ensures spectators are rejected server-side
-- even if a client somehow fires a C→S remote. (plan 6.4)
function SpectatorService.isSpectator(player: Player): boolean
	return PlayerRegistry.getState(player) == State.Spectator
end

-- Serve the current Alive player list for client-side camera cycling. (plan 6.2)
-- Called once from ServerBoot.
function SpectatorService.start()
	SpectatorTargets.OnServerInvoke = function(_player: Player)
		return PlayerRegistry.getAlive()
	end
end

return SpectatorService
