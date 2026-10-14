--!strict
-- InputController.luau  (ModuleScript, StarterPlayerScripts/Client)
-- Relays player intent (Alien transform toggle + attack, Freeze Gun fire) to the server.
-- The server validates role and guards; the client never decides effects.
-- (specs §6, §7, plan 4.4, 5.2)

local Players          = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local Workspace        = game:GetService("Workspace")

local LocalPlayer = Players.LocalPlayer

local HudController = require(script.Parent:WaitForChild("HudController"))

local Remotes          = ReplicatedStorage:WaitForChild("Remotes")
local TransformToggled = Remotes:WaitForChild("TransformToggled") :: RemoteEvent
local AlienAttacked    = Remotes:WaitForChild("AlienAttacked")    :: RemoteEvent
local FreezeFired      = Remotes:WaitForChild("FreezeFired")      :: RemoteEvent

local AIM_DISTANCE = 1000 -- matches GameConfig.FREEZE_RANGE; the server re-clamps the ray

local InputController = {}

-- Tools already wired. A tool returns to the Backpack on every unequip, which fires
-- ChildAdded again — without this it would collect duplicate connections.
local hooked: { [Tool]: boolean } = setmetatable({}, { __mode = "k" }) :: any

-- World point under the cursor, ignoring our own character. The server raycasts from
-- the gun muzzle toward this point, so a sky shot still yields a valid direction.
local function getAimPoint(): Vector3?
	local camera = Workspace.CurrentCamera
	if not camera then
		return nil
	end
	local mouse = UserInputService:GetMouseLocation()
	local ray = camera:ViewportPointToRay(mouse.X, mouse.Y)

	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	local character = LocalPlayer.Character
	if character then
		params.FilterDescendantsInstances = { character }
	end

	local result = Workspace:Raycast(ray.Origin, ray.Direction * AIM_DISTANCE, params)
	if result then
		return result.Position
	end
	return ray.Origin + ray.Direction * AIM_DISTANCE
end

-- Wire equip, unequip and activate on a Transform tool instance.
local function hookTransformTool(tool: Tool)
	tool.Equipped:Connect(function()
		TransformToggled:FireServer(true)
	end)
	tool.Unequipped:Connect(function()
		TransformToggled:FireServer(false)
	end)
	-- Activated fires on left-click/tap while the tool is equipped. (specs §6 "attack")
	tool.Activated:Connect(function()
		AlienAttacked:FireServer()
	end)
end

-- Wire the Freeze Gun: a click sends the aim point; the server does the raycast,
-- cooldown and resolution. (specs §7, plan 5.2)
local function hookFreezeGun(tool: Tool)
	-- The crosshair stands in for the cursor while the gun is in hand.
	tool.Equipped:Connect(function()
		HudController.setCrosshairVisible(true)
	end)
	tool.Unequipped:Connect(function()
		HudController.setCrosshairVisible(false)
	end)
	tool.Activated:Connect(function()
		local aim = getAimPoint()
		if aim then
			FreezeFired:FireServer(aim)
		end
	end)
end

local function hookTool(tool: Tool)
	if hooked[tool] then
		return
	end
	if tool.Name == "Transform" then
		hooked[tool] = true
		hookTransformTool(tool)
	elseif tool.Name == "Freeze Gun" then
		hooked[tool] = true
		hookFreezeGun(tool)
	end
end

-- Watch the Backpack for tools being granted (round start, or a gun pickup).
-- LoadCharacter clears the Backpack each round, so ChildAdded fires again for each
-- new tool and we get a fresh set of connections automatically.
local function watchBackpack(backpack: Instance)
	for _, child in backpack:GetChildren() do
		if child:IsA("Tool") then
			hookTool(child)
		end
	end

	backpack.ChildAdded:Connect(function(child)
		if child:IsA("Tool") then
			hookTool(child)
		end
	end)
end

function InputController.init()
	-- The Backpack can be replaced when a character respawns, so watch for new ones too.
	LocalPlayer.ChildAdded:Connect(function(child)
		if child:IsA("Backpack") then
			watchBackpack(child)
		end
	end)
	local backpack = LocalPlayer:FindFirstChildOfClass("Backpack")
	if backpack then
		watchBackpack(backpack)
	end
end

return InputController
