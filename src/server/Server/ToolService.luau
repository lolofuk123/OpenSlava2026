--!strict
-- ToolService.luau  (ModuleScript, ServerScriptService/Server)
-- Grants role-specific tools to players after characters load. The tools themselves are
-- authored in ServerStorage/Tools ("Transform" and "Freeze Gun"); this clones them.
-- (specs §4 step 3, plan 5.1)

local ServerStorage = game:GetService("ServerStorage")

local TOOLS_FOLDER = "Tools"
local FREEZE_GUN   = "Freeze Gun" -- must match FreezeService's GUN_NAME

local ToolService = {}

-- A fresh clone of the named tool from ServerStorage/Tools, or nil (with a warning) if it
-- is missing. Dropping is disabled on the clone: a dropped Tool would sit loose in the
-- world, where anyone — including the Alien — could pick it up. FreezeService drops the
-- gun as a prompt part instead.
function ToolService.cloneTool(name: string): Tool?
	local folder = ServerStorage:FindFirstChild(TOOLS_FOLDER)
	local template = folder and folder:FindFirstChild(name)
	if not template or not template:IsA("Tool") then
		warn(`[ToolService] Tool '{name}' not found in ServerStorage/{TOOLS_FOLDER}`)
		return nil
	end
	local tool = template:Clone()
	tool.CanBeDropped = false
	return tool
end

-- Put a fresh Freeze Gun in the player's Backpack.
function ToolService.grantFreezeGun(player: Player)
	local backpack = player:WaitForChild("Backpack", 5)
	if not backpack then
		warn(`[ToolService] No Backpack found for '{player.Name}'`)
		return
	end

	local tool = ToolService.cloneTool(FREEZE_GUN)
	if tool then
		tool.Parent = backpack
	end
end

-- Remove all Tools from a player's Backpack and equipped slot.
function ToolService.clearTools(player: Player)
	local backpack = player:FindFirstChildOfClass("Backpack")
	if backpack then
		for _, item in backpack:GetChildren() do
			if item:IsA("Tool") then
				item:Destroy()
			end
		end
	end
	local character = player.Character
	if character then
		for _, item in character:GetChildren() do
			if item:IsA("Tool") then
				item:Destroy()
			end
		end
	end
end

return ToolService
