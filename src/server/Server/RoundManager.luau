--!strict
-- RoundManager.luau  (ModuleScript, ServerScriptService/Server)
-- Round lifecycle state machine. (specs §4, plan 2.3 / 2.4 / 2.5 / 2.6 / 2.7)
--
-- Phase 2 scope: cycles Lobby -> Assigning -> Teleporting -> Active -> Ending ->
-- Intermission -> loop. Roster is real; roles are all stubbed to Human (Phase 3
-- will replace the Assigning stub with RoleService).

local Players             = game:GetService("Players")
local ReplicatedStorage   = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local Workspace           = game:GetService("Workspace")

local Shared     = ReplicatedStorage:WaitForChild("Shared")
local GameConfig = require(Shared:WaitForChild("GameConfig"))
local GameEnums  = require(Shared:WaitForChild("GameEnums"))

local Server           = ServerScriptService:WaitForChild("Server")
local PlayerRegistry   = require(Server:WaitForChild("PlayerRegistry"))
local TeleportService  = require(Server:WaitForChild("TeleportService"))
local SpectatorService = require(Server:WaitForChild("SpectatorService"))
local RoleService      = require(Server:WaitForChild("RoleService"))
local ToolService      = require(Server:WaitForChild("ToolService"))
local AlienService     = require(Server:WaitForChild("AlienService"))
local FreezeService    = require(Server:WaitForChild("FreezeService"))
local WinService       = require(Server:WaitForChild("WinService"))
local LabTubeService   = require(Server:WaitForChild("LabTubeService"))

local Remotes           = ReplicatedStorage:WaitForChild("Remotes")
local RoundStateChanged = Remotes:WaitForChild("RoundStateChanged") :: RemoteEvent
local RoundResult       = Remotes:WaitForChild("RoundResult")       :: RemoteEvent

local Phase = GameEnums.RoundPhase
local State = GameEnums.PlayerState
local Role  = GameEnums.Role

local RoundManager = {}

-- Authoritative current phase; read by the join/leave handlers. (plan 2.5)
local currentPhase: GameEnums.RoundPhase = Phase.Lobby

-- Broadcast phase + optional absolute end-time to every client. `needed` is only
-- used in Lobby: how many more players are required before the countdown starts.
-- (plan 2.4)
local function broadcastPhase(phase: GameEnums.RoundPhase, endTime: number?, needed: number?)
	currentPhase = phase
	RoundStateChanged:FireAllClients(phase, endTime, needed)
end

-- Number of players currently eligible to be rostered (sitting in the lobby).
local function eligibleCount(): number
	return #PlayerRegistry.getLobbyPlayers()
end

-- ── Player event handlers ─────────────────────────────────────────────────────

-- New player: join lobby if the server is between rounds; spectate if mid-round.
-- (specs §3.3, plan 2.5)
local function onPlayerAdded(player: Player)
	PlayerRegistry.register(player)
	local isActive = currentPhase ~= Phase.Lobby and currentPhase ~= Phase.Intermission
	if isActive then
		-- Mid-round joiner: immediate Spectator, no character loaded. (specs §8, plan 6.1)
		SpectatorService.enter(player)
	else
		-- Between rounds: join the lobby. lobbySpawn yields, so run it off the
		-- PlayerAdded callback to avoid blocking it.
		PlayerRegistry.setState(player, State.Lobby)
		task.spawn(function()
			TeleportService.lobbySpawn(player)
		end)
	end
end

-- Disconnect: remove from both the per-player record and the fixed roster so that
-- any in-progress win checks (Phase 7) only see currently-connected players.
-- (specs §3.3, plan 2.6)
local function onPlayerRemoving(player: Player)
	local wasRostered = PlayerRegistry.isInRoster(player)
	-- Capture the role BEFORE remove() wipes it — we need to know if the Alien left.
	local wasAlien = PlayerRegistry.getRole(player) == Role.Alien
	PlayerRegistry.remove(player)  -- clears record AND drops from roster
	if wasRostered then
		print(`[RoundManager] '{player.Name}' disconnected mid-round — removed from roster`)
	end
	if wasAlien then
		-- Alien left → round ends immediately, no winner. abort() no-ops if the
		-- round isn't live (e.g. they left during Ending/Intermission). (plan 7.5)
		WinService.abort()
	else
		-- A leaving participant may have been the last Alive non-Alien. (plan 7.1)
		WinService.check()
	end
end

-- ── Round timer ───────────────────────────────────────────────────────────────

-- Lobby: hold until MIN_PLAYERS are present, then run INTERMISSION_SECONDS before
-- returning. If the count drops below MIN_PLAYERS mid-countdown, it resets to waiting.
-- This countdown IS the between-rounds intermission (runs after every round too).
-- Lobby state is re-broadcast every tick so players who join (or whose client loads)
-- late still receive the current waiting/countdown text.
local function waitForRoundStart()
	local countdownDeadline: number? = nil  -- os.clock deadline, nil while waiting
	local countdownEndTime: number? = nil   -- same moment in GetServerTimeNow() terms, for clients
	while true do
		local needed = GameConfig.MIN_PLAYERS - eligibleCount()
		local interval = 0.5
		if needed > 0 then
			countdownDeadline = nil
			countdownEndTime = nil
			broadcastPhase(Phase.Lobby, nil, needed)
		else
			if countdownDeadline == nil then
				countdownDeadline = os.clock() + GameConfig.INTERMISSION_SECONDS
				countdownEndTime = Workspace:GetServerTimeNow() + GameConfig.INTERMISSION_SECONDS
			elseif os.clock() >= countdownDeadline then
				return
			end
			broadcastPhase(Phase.Lobby, countdownEndTime, 0)
			-- Don't overshoot the deadline by a full tick.
			interval = math.clamp((countdownDeadline :: number) - os.clock(), 0.05, 0.5)
		end
		task.wait(interval)
	end
end

-- Hold the Active phase until the round timer expires OR a win-check decides an
-- outcome early (abduction / freeze / leave). Uses os.clock so drift doesn't
-- accumulate; polls at the same cadence as the win-checks. (plan 2.4 / 7.1)
local function waitForRoundEnd()
	local deadline = os.clock() + GameConfig.ROUND_SECONDS
	while os.clock() < deadline and not WinService.isDecided() do
		task.wait(0.25)
	end
end

-- ── Teleport helpers ──────────────────────────────────────────────────────────

-- Spawn all players in `list` concurrently and wait up to `timeout` seconds for
-- all of them to land. Returns when everyone is done (or the deadline expires).
local function spawnAllConcurrent(
	list: { Player },
	spawnFn: (player: Player, index: number) -> (),
	timeout: number
)
	if #list == 0 then return end
	local done = 0
	for index, player in list do
		task.spawn(function()
			spawnFn(player, index)
			done += 1
		end)
	end
	local deadline = os.clock() + timeout
	while done < #list and os.clock() < deadline do
		task.wait(0.25)
	end
end

-- ── Main loop ─────────────────────────────────────────────────────────────────

-- Names of the Alive non-Alien players, sorted, for the result screen's survivor list.
-- Must run before roles and states are reset at round end.
local function survivorNames(): { string }
	local names: { string } = {}
	for _, player in PlayerRegistry.getAlive() do
		if PlayerRegistry.getRole(player) ~= Role.Alien then
			table.insert(names, player.Name)
		end
	end
	table.sort(names)
	return names
end

local function runLoop()
	while true do
		-- 1. Lobby — wait for MIN_PLAYERS, then count down before the round starts.
		--    (specs §4 step 1)
		waitForRoundStart()

		-- 2. Assigning — snapshot the roster, mark everyone Alive, then assign real
		--    roles (1 Alien + 1 Scientist, rest Human) via RoleService.
		--    RoleService also fires the private RoleAssigned event to each player.
		--    (specs §4 step 2, specs §5, plan 3.2 / 3.3)
		broadcastPhase(Phase.Assigning, nil)
		local roster = PlayerRegistry.getLobbyPlayers()
		PlayerRegistry.setRoster(roster)
		for _, player in roster do
			PlayerRegistry.setState(player, State.Alive)
		end
		RoleService.assign(roster)
		-- Arm the win-check now that roles/states are fully set. (plan 7.1)
		WinService.beginRound()

		-- 3. Teleporting — load every roster character at a map spawn, concurrently,
		--    then grant role-specific tools. (specs §4 step 3, plan 5.1)
		broadcastPhase(Phase.Teleporting, nil)
		spawnAllConcurrent(roster, TeleportService.loadAtMap, 20)
		for _, player in roster do
			local role = PlayerRegistry.getRole(player)
			if role == Role.Alien then
				AlienService.grantTransformTool(player)
			elseif role == Role.Scientist then
				ToolService.grantFreezeGun(player)
			end
		end

		-- 4. Active — broadcast the absolute end-time so clients can render a countdown
		--    without clock skew. (specs §4 step 4, plan 2.4)
		local endTime = Workspace:GetServerTimeNow() + GameConfig.ROUND_SECONDS
		broadcastPhase(Phase.Active, endTime)
		waitForRoundEnd()
		-- Timer expired with both sides still alive → Draw. An aborted round (Alien
		-- left) is already decided with no outcome, so this is skipped. (specs §10.3, plan 7.1/7.5)
		if not WinService.isDecided() then
			WinService.declareDraw()
		end

		-- 5/6. Ending — announce the outcome, strip state, teleport everyone (alive +
		--      spectators) back to lobby concurrently, then clear the roster. (plan 2.7 / 7.1)
		broadcastPhase(Phase.Ending, nil)

		-- Announce the decided outcome to all clients. (specs §4 step 6, plan 7.1)
		local result = WinService.getOutcome()
		if result then
			RoundResult:FireAllClients(result, survivorNames())
		end

		-- Remove any dropped Freeze Gun from the map before lobbying everyone out. (plan 5.7)
		FreezeService.clearDrop()
		-- Remove the Lab Tubes left where players were abducted.
		LabTubeService.clear()

		-- Strip Transform and Freeze Gun tools from every player. The Backpack survives
		-- LoadCharacter, so tools must be cleared explicitly or they'd carry into the next
		-- round. clearTools covers both the Backpack and the equipped (character) slot. (plan 7.9)
		for _, player in Players:GetPlayers() do
			ToolService.clearTools(player)
		end

		-- Reset roles and states first so no stale Alive/role data lingers.
		for _, player in Players:GetPlayers() do
			PlayerRegistry.setState(player, State.Lobby)
			PlayerRegistry.setRole(player, Role.None)
		end
		-- Teleport all connected players back to the lobby concurrently.
		spawnAllConcurrent(Players:GetPlayers(), TeleportService.lobbySpawn, 20)
		PlayerRegistry.clearRoster()
		-- 7. Intermission — the loop returns to Lobby, whose countdown (waitForRoundStart)
		--    is the intermission. (specs §4 step 7)
	end
end

-- ── Public API ────────────────────────────────────────────────────────────────

-- Wire player events and kick off the state machine. Called once from ServerBoot.
function RoundManager.start()
	-- A landed freeze on the Alien resolves to a human-team win. (specs §10.2, plan 7.1)
	FreezeService.setAlienFrozenHandler(function(_shooter: Player, _alien: Player)
		WinService.declareHumanWin()
	end)
	Players.PlayerAdded:Connect(onPlayerAdded)
	Players.PlayerRemoving:Connect(onPlayerRemoving)
	-- Register any players already present when the server boots (Studio Play Solo).
	for _, player in Players:GetPlayers() do
		onPlayerAdded(player)
	end
	task.spawn(runLoop)
end

return RoundManager
