--!strict
-- SpectatorController.luau  (ModuleScript, StarterPlayerScripts/Client)
-- Camera cycling for spectators. (specs §8, plan 6.3)
--
-- A spectator has no character of their own (the server removes it on entry, see
-- SpectatorService). This controller points the camera at currently-Alive players
-- and lets the local player cycle next/previous between them with the arrow keys.
--
-- There is no dedicated "you are spectating" remote (specs §12 has none), so
-- spectator status is inferred: if the alive list is non-empty and the local
-- player is not in it, the local player is spectating. This covers abduction,
-- wrong-freeze elimination, and mid-round joins with a single rule. The alive
-- list is polled from the SpectatorTargets RemoteFunction and refreshed
-- immediately on AbductionOccurred so the camera retargets the moment the list
-- changes.

local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService        = game:GetService("RunService")
local UserInputService  = game:GetService("UserInputService")
local Workspace         = game:GetService("Workspace")

local localPlayer = Players.LocalPlayer

local HudController = require(script.Parent:WaitForChild("HudController"))

local Remotes           = ReplicatedStorage:WaitForChild("Remotes")
local SpectatorTargets   = Remotes:WaitForChild("SpectatorTargets") :: RemoteFunction
local AbductionOccurred  = Remotes:WaitForChild("AbductionOccurred") :: RemoteEvent
local RoundStateChanged  = Remotes:WaitForChild("RoundStateChanged") :: RemoteEvent

local POLL_INTERVAL = 1 -- seconds between alive-list refreshes

local SpectatorController = {}

local targets: { Player } = {} -- currently-Alive players, excluding the local player
local currentIndex = 0         -- index into `targets` of the viewed player; 0 = none
local spectating = false
local renderConn: RBXScriptConnection? = nil

-- Point the camera at whichever target is currently selected. Runs every frame
-- while spectating so it re-acquires the subject if the target's character is
-- still loading or gets swapped (e.g. the Alien transforming).
local function onRender()
	local camera = Workspace.CurrentCamera
	if not camera then
		return
	end
	local target = targets[currentIndex]
	if not target then
		return
	end
	local character = target.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if humanoid and camera.CameraSubject ~= humanoid then
		camera.CameraType = Enum.CameraType.Custom
		camera.CameraSubject = humanoid
	end
end

-- Hand the camera back to the local player (used when leaving spectator state).
local function restoreCamera()
	local camera = Workspace.CurrentCamera
	if not camera then
		return
	end
	camera.CameraType = Enum.CameraType.Custom
	local character = localPlayer.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if humanoid then
		camera.CameraSubject = humanoid
	end
end

-- Enter/leave spectator view. Only acts on an actual transition.
local function setSpectating(on: boolean)
	if on == spectating then
		return
	end
	spectating = on
	HudController.onSpectatingChanged(on)
	if on then
		renderConn = RunService.RenderStepped:Connect(onRender)
	else
		currentIndex = 0
		if renderConn then
			renderConn:Disconnect()
			renderConn = nil
		end
		restoreCamera()
	end
end

-- Sync the "Now spectating <name>" panel with the current selection.
local function updateHud()
	local target = if spectating then targets[currentIndex] else nil
	HudController.setSpectatorTarget(target, targets, currentIndex)
end

-- Move the view to the next/previous alive player (wraps around).
local function cycle(delta: number)
	if not spectating or #targets == 0 then
		return
	end
	currentIndex = ((currentIndex - 1 + delta) % #targets) + 1
	onRender()
	updateHud()
end

local function isLocalAlive(aliveList: { Player }): boolean
	for _, player in aliveList do
		if player == localPlayer then
			return true
		end
	end
	return false
end

-- Pull the current alive list from the server, decide spectator status, and keep
-- the selected index valid against the new list.
local function refresh()
	local ok, result = pcall(function()
		return SpectatorTargets:InvokeServer()
	end)
	local aliveList: { Player } = {}
	if ok and typeof(result) == "table" then
		aliveList = result
	end

	HudController.setAlivePlayers(aliveList)

	targets = {}
	for _, player in aliveList do
		if player ~= localPlayer then
			table.insert(targets, player)
		end
	end

	-- Spectating when a round is in play (someone is Alive) but we are not.
	setSpectating(#aliveList > 0 and not isLocalAlive(aliveList))

	if spectating then
		if currentIndex < 1 or currentIndex > #targets then
			currentIndex = if #targets > 0 then 1 else 0
		end
		onRender()
	end
	updateHud()
end

local function onInput(input: InputObject, gameProcessed: boolean)
	if gameProcessed or not spectating then
		return
	end
	if input.KeyCode == Enum.KeyCode.Right then
		cycle(1)
	elseif input.KeyCode == Enum.KeyCode.Left then
		cycle(-1)
	end
end

-- Returns whether the local player is currently in spectator view. Used by
-- InputController (Phase 4) to gate game-affecting remotes on the client so that
-- a spectator never even sends intent to the server. (plan 6.4)
function SpectatorController.isSpectating(): boolean
	return spectating
end

function SpectatorController.init()
	UserInputService.InputBegan:Connect(onInput)
	HudController.setSpectatorCycleHandler(cycle)
	-- Retarget immediately when an abduction changes the alive list.
	AbductionOccurred.OnClientEvent:Connect(refresh)
	-- End spectating immediately when the round ends (Ending / Lobby / Intermission).
	-- Without this the 1-second poll would leave a stale spectator camera for up to
	-- 1s after the server has already reset states and begun loading lobby characters.
	-- (plan 6.4 / 6.5)
	-- The server re-broadcasts Lobby state periodically (waiting/countdown HUD), so only
	-- react to actual phase changes.
	local lastPhase = ""
	RoundStateChanged.OnClientEvent:Connect(function(phase: string)
		if phase == lastPhase then
			return
		end
		lastPhase = phase
		if phase == "Ending" or phase == "Lobby" or phase == "Intermission" then
			refresh()
		end
	end)
	-- Steady poll catches mid-round joins and eliminations that aren't broadcast.
	task.spawn(function()
		while true do
			refresh()
			task.wait(POLL_INTERVAL)
		end
	end)
end

return SpectatorController
