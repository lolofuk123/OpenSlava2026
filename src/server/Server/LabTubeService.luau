--!strict
-- LabTubeService.luau  (ModuleScript, ServerScriptService/Server)
-- Drops a decorative "Lab Tube" model where a player was abducted by the Alien, standing
-- on the floor at the spot the victim was, with a semi-transparent copy of the victim's
-- character inside. Tubes live in Workspace/LabTubes and are removed at round end.
-- Purely cosmetic: no collision, never blocks a Freeze Gun shot.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace         = game:GetService("Workspace")

local TEMPLATE_NAME = "Lab Tube"   -- model in ReplicatedStorage
local FOLDER_NAME   = "LabTubes"
local FLOOR_SEARCH  = 12           -- studs to look down for the floor under the victim
local BODY_TRANSPARENCY = 0.5      -- how see-through the "dead" body inside the tube is

local LabTubeService = {}

local function getFolder(): Folder
	local existing = Workspace:FindFirstChild(FOLDER_NAME)
	if existing and existing:IsA("Folder") then
		return existing
	end
	local folder = Instance.new("Folder")
	folder.Name = FOLDER_NAME
	folder.Parent = Workspace
	return folder
end

-- World Y of the floor beneath the victim; falls back to their standing height when the
-- ray finds nothing (e.g. standing on a part with CanQuery off).
local function floorY(character: Model, hrp: BasePart, humanoid: Humanoid?): number
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { character, getFolder() }
	local result = Workspace:Raycast(hrp.Position, Vector3.new(0, -FLOOR_SEARCH, 0), params)
	if result then
		return result.Position.Y
	end
	local hip = if humanoid then humanoid.HipHeight else 2
	return hrp.Position.Y - hrp.Size.Y / 2 - hip
end

-- World Y of the lowest point of a box with the given CFrame and size (any orientation).
local function bottomY(boxCFrame: CFrame, boxSize: Vector3): number
	local halfHeight = (
		math.abs(boxCFrame.XVector.Y) * boxSize.X
		+ math.abs(boxCFrame.YVector.Y) * boxSize.Y
		+ math.abs(boxCFrame.ZVector.Y) * boxSize.Z
	) / 2
	return boxCFrame.Position.Y - halfHeight
end

-- Distance from a model's pivot down to the lowest point of its bounding box, so it can
-- be set exactly on a floor whatever orientation it was authored in.
local function pivotAboveBottom(model: Model): number
	local boxCFrame, boxSize = model:GetBoundingBox()
	return model:GetPivot().Position.Y - bottomY(boxCFrame, boxSize)
end

-- World Y of the tube's inner floor: the bottom of its glass (the semi-transparent parts).
local function interiorFloorY(tube: Model, fallback: number): number
	local lowest: number? = nil
	for _, descendant in tube:GetDescendants() do
		if descendant:IsA("BasePart") and descendant.Transparency >= 0.5 then
			local y = bottomY(descendant.CFrame, descendant.Size)
			if lowest == nil or y < lowest then
				lowest = y
			end
		end
	end
	return lowest or fallback
end

-- A static, ghost-like copy of the victim's character: anchored, non-colliding, no scripts
-- or tools, every visible part semi-transparent. Nil if the character can't be cloned.
local function makeGhostBody(character: Model): Model?
	character.Archivable = true
	local body = character:Clone()
	if not body then
		return nil
	end
	body.Name = "AbductedBody" -- not the player's name, so nothing mistakes it for them

	for _, descendant in body:GetDescendants() do
		if descendant:IsA("LuaSourceContainer") or descendant:IsA("Tool") then
			descendant:Destroy()
		end
	end
	for _, descendant in body:GetDescendants() do
		if descendant:IsA("BasePart") then
			descendant.Anchored = true
			descendant.CanCollide = false
			descendant.CanQuery = false
			descendant.CanTouch = false
			-- HumanoidRootPart is already invisible (1); only fade parts that are more solid.
			descendant.Transparency = math.max(descendant.Transparency, BODY_TRANSPARENCY)
		elseif descendant:IsA("Decal") or descendant:IsA("Texture") then
			descendant.Transparency = math.max(descendant.Transparency, BODY_TRANSPARENCY)
		end
	end

	local humanoid = body:FindFirstChildOfClass("Humanoid")
	if humanoid then
		humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
		humanoid.HealthDisplayType = Enum.HumanoidHealthDisplayType.AlwaysOff
	end
	return body
end

-- Spawn a tube at the player's current position. Call BEFORE their character is removed.
function LabTubeService.spawnAt(player: Player)
	local template = ReplicatedStorage:FindFirstChild(TEMPLATE_NAME)
	if not template or not template:IsA("Model") then
		warn(`[LabTubeService] '{TEMPLATE_NAME}' model not found in ReplicatedStorage`)
		return
	end
	local character = player.Character
	local hrp = character and character:FindFirstChild("HumanoidRootPart")
	if not character or not hrp or not hrp:IsA("BasePart") then
		return
	end

	local tube = template:Clone()
	-- The template's parts are loose and non-colliding: anchor them so the tube stays put,
	-- and make them invisible to raycasts so the glass can't block a Freeze Gun shot.
	for _, descendant in tube:GetDescendants() do
		if descendant:IsA("BasePart") then
			descendant.Anchored = true
			descendant.CanCollide = false
			descendant.CanQuery = false
			descendant.CanTouch = false
		end
	end

	local pivot = tube:GetPivot()
	local upright = pivot - pivot.Position -- keep the authored orientation, drop its position
	local base = floorY(character, hrp, character:FindFirstChildOfClass("Humanoid"))
	tube:PivotTo(CFrame.new(hrp.Position.X, base + pivotAboveBottom(tube), hrp.Position.Z) * upright)

	-- The victim's ghost stands inside, feet on the tube's inner floor, facing the way they did.
	local body = makeGhostBody(character)
	if body then
		local look = hrp.CFrame.LookVector
		local flatLook = Vector3.new(look.X, 0, look.Z)
		local facing = if flatLook.Magnitude > 0.001
			then CFrame.lookAt(Vector3.zero, flatLook)
			else CFrame.identity
		local feetY = interiorFloorY(tube, base)
		body:PivotTo(CFrame.new(hrp.Position.X, feetY + pivotAboveBottom(body), hrp.Position.Z) * facing)
		body.Parent = tube
	else
		warn(`[LabTubeService] could not copy '{player.Name}' — spawning an empty tube`)
	end

	tube.Parent = getFolder()
end

-- Remove every tube. Called at round end.
function LabTubeService.clear()
	local folder = Workspace:FindFirstChild(FOLDER_NAME)
	if folder then
		folder:ClearAllChildren()
	end
end

return LabTubeService
