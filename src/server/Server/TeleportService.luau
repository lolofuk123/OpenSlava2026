--!strict
-- TeleportService.luau  (ModuleScript, ServerScriptService/Server)
-- Server-owned spawning: loads characters at the lobby or at the round's start point
-- and moves characters between them via CFrame. (specs §9, plan 2.2)
--
-- Geometry convention: the lobby is the part "LobbySpawn" inside the Workspace MODEL
-- "Lobby"; round starts use the part "BaseSpawnPart" inside the Workspace folder
-- "Military Base", spread randomly around it. Warns and no-ops if missing.

local Players   = game:GetService("Players")
local Workspace = game:GetService("Workspace")

local LOBBY_MODEL  = "Lobby"
local LOBBY_SPAWN  = "LobbySpawn"
local BASE_FOLDER  = "Military Base"
local BASE_SPAWN   = "BaseSpawnPart"
local BASE_SPREAD  = 10                   -- studs, +/- on both X and Z around BaseSpawnPart
local GROUND_RAY   = 50                   -- studs above/below BaseSpawnPart to look for ground
local STAND_HEIGHT = 4                    -- HumanoidRootPart height above the ground it lands on
local SPAWN_OFFSET = Vector3.new(0, 3, 0) -- lift above pad to avoid floor-clip on spawn
local LOAD_TIMEOUT = 15                   -- seconds before giving up on a character load

local rng = Random.new()

local TeleportService = {}

-- The LobbySpawn part inside the Workspace *Model* named "Lobby". A plain FindFirstChild
-- isn't enough: Workspace can also hold a Folder with the same name, which it might return.
local function findLobbyPad(): BasePart?
	for _, child in Workspace:GetChildren() do
		if child.Name == LOBBY_MODEL and child:IsA("Model") then
			local pad = child:FindFirstChild(LOBBY_SPAWN)
			if pad and pad:IsA("BasePart") then
				return pad
			end
		end
	end
	return nil
end

-- Pivot a player's character onto the LobbySpawn pad, at a random spot within its footprint
-- so players arriving together don't stack on a single point.
local function moveToLobbyPad(player: Player)
	local character = player.Character
	if not character then
		return
	end
	local pad = findLobbyPad()
	if not pad then
		warn(`TeleportService: model '{LOBBY_MODEL}' with part '{LOBBY_SPAWN}' not found in Workspace`)
		return
	end
	local dx = rng:NextNumber(-pad.Size.X / 2, pad.Size.X / 2)
	local dz = rng:NextNumber(-pad.Size.Z / 2, pad.Size.Z / 2)
	character:PivotTo(pad.CFrame * CFrame.new(dx, 0, dz) + SPAWN_OFFSET)
end

-- Pivot a player's character to a random spot within BASE_SPREAD studs (on X and Z) of the
-- BaseSpawnPart. The base is dense with fences, crates and buildings, so a ray is cast
-- straight down at the chosen spot and the player is stood on whatever it hits, rather
-- than risking a spawn inside geometry.
local function moveToBase(player: Player)
	local character = player.Character
	if not character then
		return
	end
	local folder = Workspace:FindFirstChild(BASE_FOLDER)
	local spawnPart = folder and folder:FindFirstChild(BASE_SPAWN)
	if not spawnPart or not spawnPart:IsA("BasePart") then
		warn(`TeleportService: '{BASE_FOLDER}.{BASE_SPAWN}' not found`)
		return
	end

	local center = spawnPart.Position
	local x = center.X + rng:NextNumber(-BASE_SPREAD, BASE_SPREAD)
	local z = center.Z + rng:NextNumber(-BASE_SPREAD, BASE_SPREAD)

	local ignore: { Instance } = {}
	for _, other in Players:GetPlayers() do
		if other.Character then
			table.insert(ignore, other.Character)
		end
	end
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = ignore
	params.IgnoreWater = true

	local result = Workspace:Raycast(Vector3.new(x, center.Y + GROUND_RAY, z), Vector3.new(0, -2 * GROUND_RAY, 0), params)
	local groundY = if result then result.Position.Y else center.Y + spawnPart.Size.Y / 2
	character:PivotTo(CFrame.new(x, groundY + STAND_HEIGHT, z))
end

-- Yield until the player's character has a HumanoidRootPart, or LOAD_TIMEOUT passes.
-- LoadCharacter() is async — calling this right after ensures the pivot has a target.
-- Returns true when ready, false on timeout or player disconnect.
local function waitForReady(player: Player): boolean
	local deadline = os.clock() + LOAD_TIMEOUT
	while os.clock() < deadline do
		if player.Parent == nil then
			return false -- player left the game
		end
		local char = player.Character
		if char and char:FindFirstChild("HumanoidRootPart") then
			return true
		end
		task.wait(0.1)
	end
	warn(`TeleportService: timed out waiting for character of '{player.Name}'`)
	return false
end

-- Load a fresh character and place it at the round's start point (around BaseSpawnPart).
-- Yields until the character is ready.
function TeleportService.loadAtMap(player: Player, _index: number?)
	player:LoadCharacter()
	if waitForReady(player) then
		moveToBase(player)
	end
end

-- Load a fresh character at the lobby spawn. Yields until the character is ready.
function TeleportService.lobbySpawn(player: Player, _index: number?)
	player:LoadCharacter()
	if waitForReady(player) then
		moveToLobbyPad(player)
	end
end

-- Move an already-loaded character to the round's start point (no reload).
function TeleportService.moveToMap(player: Player, _index: number?)
	moveToBase(player)
end

-- Move an already-loaded character to the lobby (no reload).
function TeleportService.moveToLobby(player: Player, _index: number?)
	moveToLobbyPad(player)
end

return TeleportService
