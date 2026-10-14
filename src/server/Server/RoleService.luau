--!strict
-- RoleService.luau  (ModuleScript, ServerScriptService/Server)
-- Assigns 1 Alien and 1 Scientist from the roster; all others become Human.
-- Sends each player a PRIVATE RoleAssigned event — clients never learn each
-- other's roles. (specs §5, plan 3.1 / 3.3)

local ReplicatedStorage   = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Shared    = ReplicatedStorage:WaitForChild("Shared")
local GameEnums = require(Shared:WaitForChild("GameEnums"))

local Server         = ServerScriptService:WaitForChild("Server")
local PlayerRegistry = require(Server:WaitForChild("PlayerRegistry"))

local Remotes      = ReplicatedStorage:WaitForChild("Remotes")
local RoleAssigned = Remotes:WaitForChild("RoleAssigned") :: RemoteEvent

local Role = GameEnums.Role

local RoleService = {}

-- Assign roles to every player in `players`, update PlayerRegistry, and fire
-- a private RoleAssigned event to each individual player.
-- Precondition: #players >= 2 (MIN_PLAYERS = 3 guarantees this at round start).
-- Role-repeat is allowed — a player may be Alien or Scientist in consecutive rounds.
-- (specs §5: "use Random.new(), no anti-repeat weighting")
function RoleService.assign(players: { Player })
	if #players < 2 then
		warn("[RoleService] assign() called with fewer than 2 players — cannot place both roles")
		return
	end

	local rng = Random.new()

	-- Pick the Alien from the full list.
	local alienIdx = rng:NextInteger(1, #players)

	-- Pick the Scientist from the remaining positions (retry until different from Alien).
	local sciIdx: number
	repeat
		sciIdx = rng:NextInteger(1, #players)
	until sciIdx ~= alienIdx

	for i, player in players do
		local role: GameEnums.Role
		if i == alienIdx then
			role = Role.Alien
		elseif i == sciIdx then
			role = Role.Scientist
		else
			role = Role.Human
		end

		PlayerRegistry.setRole(player, role)

		-- Fire only to this player. FireClient, never FireAllClients. (specs §2)
		RoleAssigned:FireClient(player, role)
	end
end

return RoleService
