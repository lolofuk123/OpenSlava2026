--!strict
-- WinService.luau  (ModuleScript, ServerScriptService/Server)
-- Central win-condition check. (specs §10, plan 7.1)
--
-- Evaluated after every abduction, every wrong-freeze elimination, every
-- participant leave, and on timer expiry. The FIRST triggering event to resolve
-- decides the round: once an outcome is set the check is a no-op until the next
-- beginRound(). Because the server is single-threaded this gives atomicity for
-- two triggers landing in the same frame (plan 7.8).
--
-- This module depends only on PlayerRegistry + shared types, never on the services
-- that call it (AlienService / FreezeService / RoundManager), so there is no
-- require cycle. RoundManager drives beginRound/declareDraw and reads getOutcome.

local ReplicatedStorage   = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Shared     = ReplicatedStorage:WaitForChild("Shared")
local GameEnums  = require(Shared:WaitForChild("GameEnums"))
local RoundState = require(Shared:WaitForChild("RoundState"))

local Server         = ServerScriptService:WaitForChild("Server")
local PlayerRegistry = require(Server:WaitForChild("PlayerRegistry"))

local Role    = GameEnums.Role
local Outcome = RoundState.Outcome

type RoundOutcome = RoundState.RoundOutcome

local WinService = {}

-- nil until the round is decided. `active` gates every check so events that fire
-- outside a live round (e.g. a disconnect during intermission) never resolve.
local outcome: RoundOutcome? = nil
local active = false

-- Set when the Alien disconnects mid-round. The round ends immediately with NO
-- winner and NO outcome — distinct from a Draw. (specs §10 edge, plan 7.5)
local aborted = false

-- Set the outcome atomically. The first caller wins; later calls no-op until the
-- next beginRound(). (plan 7.8)
local function resolve(result: RoundOutcome)
	if not active or outcome ~= nil then
		return
	end
	outcome = result
	active = false
end

-- True if any currently-Alive player is not the Alien. (specs §10.1 phrasing —
-- "no Alive non-Aliens left" naturally covers disconnects, since getAlive only
-- returns connected players.)
local function anyAliveNonAlien(): boolean
	for _, player in PlayerRegistry.getAlive() do
		if PlayerRegistry.getRole(player) ~= Role.Alien then
			return true
		end
	end
	return false
end

-- Arm the check for a fresh round: clear the outcome. Called at Assigning.
function WinService.beginRound()
	outcome = nil
	aborted = false
	active = true
end

-- The decided outcome, or nil while the round is still running (and nil after an
-- abort — an aborted round has no winner to broadcast).
function WinService.getOutcome(): RoundOutcome?
	return outcome
end

-- True once the round is over for ANY reason: a win/draw outcome was set, or the
-- round was aborted (Alien left). RoundManager polls this to end the Active phase.
function WinService.isDecided(): boolean
	return outcome ~= nil or aborted
end

-- Alien disconnected mid-round → end the round immediately with no winner. Flips
-- `active` off so any same-frame check/declare* calls no-op, same as resolve().
-- (specs §10 edge, plan 7.5)
function WinService.abort()
	if not active then
		return
	end
	aborted = true
	active = false
end

-- Condition 1 (specs §10.1): the Alien wins once no Alive non-Alien remains.
-- Invoked after abductions, wrong-freeze eliminations, and participant leaves.
function WinService.check()
	if not active or outcome ~= nil then
		return
	end
	if not anyAliveNonAlien() then
		resolve(Outcome.AlienWin)
	end
end

-- Condition 2 (specs §10.2): the Alien was frozen → human team wins.
function WinService.declareHumanWin()
	resolve(Outcome.HumanWin)
end

-- Condition 3 (specs §10.3): the round timer expired with no winner → Draw.
function WinService.declareDraw()
	resolve(Outcome.Draw)
end

return WinService
