--!strict
-- PlayerRegistry.luau  (ModuleScript, ServerScriptService/Server)
-- Tracks per-player PlayerState + Role and the fixed round roster. (specs §3, plan 2.1)
-- Pure state store: it does not connect to Players events — RoundManager wires those.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared      = ReplicatedStorage:WaitForChild("Shared")
local GameEnums   = require(Shared:WaitForChild("GameEnums"))
local RoundState  = require(Shared:WaitForChild("RoundState"))

type Role              = RoundState.Role
type PlayerState       = RoundState.PlayerState
type ParticipantRecord = RoundState.ParticipantRecord

local PlayerRegistry = {}

-- One record per connected player; roster is the subset fixed at Assigning (specs §3.3).
local records: { [Player]: ParticipantRecord } = {}
local roster: { Player } = {}

-- Create a default record (Lobby / None) if the player has none yet.
function PlayerRegistry.register(player: Player)
	if records[player] then
		return
	end
	records[player] = {
		player = player,
		role = GameEnums.Role.None,
		state = GameEnums.PlayerState.Lobby,
	}
end

-- Forget a player entirely and drop them from the roster (disconnect, specs §3.3).
function PlayerRegistry.remove(player: Player)
	records[player] = nil
	for i = #roster, 1, -1 do
		if roster[i] == player then
			table.remove(roster, i)
		end
	end
end

function PlayerRegistry.get(player: Player): ParticipantRecord?
	return records[player]
end

function PlayerRegistry.getState(player: Player): PlayerState?
	local record = records[player]
	return record and record.state or nil
end

function PlayerRegistry.setState(player: Player, state: PlayerState)
	local record = records[player]
	if record then
		record.state = state
	end
end

function PlayerRegistry.getRole(player: Player): Role?
	local record = records[player]
	return record and record.role or nil
end

function PlayerRegistry.setRole(player: Player, role: Role)
	local record = records[player]
	if record then
		record.role = role
	end
end

-- All currently-connected players whose state is Alive.
function PlayerRegistry.getAlive(): { Player }
	local alive: { Player } = {}
	for player, record in records do
		if record.state == GameEnums.PlayerState.Alive then
			table.insert(alive, player)
		end
	end
	return alive
end

-- Players sitting in the lobby (eligible to be rostered next round).
function PlayerRegistry.getLobbyPlayers(): { Player }
	local lobby: { Player } = {}
	for player, record in records do
		if record.state == GameEnums.PlayerState.Lobby then
			table.insert(lobby, player)
		end
	end
	return lobby
end

-- Fix the roster for the round (copy so callers can't mutate internal state).
function PlayerRegistry.setRoster(players: { Player })
	roster = table.clone(players)
end

function PlayerRegistry.getRoster(): { Player }
	return table.clone(roster)
end

function PlayerRegistry.isInRoster(player: Player): boolean
	return table.find(roster, player) ~= nil
end

function PlayerRegistry.clearRoster()
	roster = {}
end

return PlayerRegistry
