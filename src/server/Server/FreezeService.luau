--!strict
-- FreezeService.luau  (ModuleScript, ServerScriptService/Server)
-- Freeze Gun fire handling + freeze resolution. (specs §7, §10, plan 5.2 / 5.3)
--
-- Fire flow (5.2): the holder's client fires FreezeFired with an aim point. The
-- server validates the firer is an Alive gun holder and is off cooldown, then
-- raycasts from the gun muzzle toward the aim point (length FREEZE_RANGE). The
-- raycast itself enforces line-of-sight — a wall between muzzle and target is hit
-- first and the shot is a miss. Cooldown is consumed on EVERY fire (hit or miss).
--
-- Resolution (5.3) keys off the target's server-side Role, never its visual form:
--   * target is the Alien  → Alien frozen → human team wins (Phase 7 hook)
--   * target is anyone else → wrong freeze → shooter AND target eliminated
--   * self-hits are ignored
--
-- Phase 7 wires setAlienFrozenHandler to resolve the round; until then an Alien
-- freeze only logs. The wrong-freeze win check is added in plan 7.1.

local Debris               = game:GetService("Debris")
local Players             = game:GetService("Players")
local ReplicatedStorage   = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local Workspace           = game:GetService("Workspace")

local Shared     = ReplicatedStorage:WaitForChild("Shared")
local GameConfig = require(Shared:WaitForChild("GameConfig"))
local GameEnums  = require(Shared:WaitForChild("GameEnums"))

local Server           = ServerScriptService:WaitForChild("Server")
local PlayerRegistry   = require(Server:WaitForChild("PlayerRegistry"))
local SpectatorService = require(Server:WaitForChild("SpectatorService"))
local ToolService      = require(Server:WaitForChild("ToolService"))
local WinService       = require(Server:WaitForChild("WinService"))
local SoundEffects     = require(Server:WaitForChild("SoundEffects"))

local Remotes        = ReplicatedStorage:WaitForChild("Remotes")
local FreezeFired    = Remotes:WaitForChild("FreezeFired")    :: RemoteEvent
local FreezeCooldown = Remotes:WaitForChild("FreezeCooldown") :: RemoteEvent
local FreezeHit      = Remotes:WaitForChild("FreezeHit")      :: RemoteEvent

local Role  = GameEnums.Role
local State = GameEnums.PlayerState

local GUN_NAME = "Freeze Gun"  -- must match the tool's name in ServerStorage/Tools

-- Shot visuals (cosmetic only).
local SHOT_COLOR         = Color3.fromRGB(0, 180, 255) -- matches the gun's colour
local SHOT_VISIBLE_LIFE  = 0.15                        -- seconds the beam stays up
local SHOT_MAX_LENGTH    = 300                         -- beam length cap for misses (studs)

-- Dropped-gun visuals (cosmetic only).
local DROP_COLOR      = Color3.fromRGB(0, 200, 255) -- sparkle / glow colour
local DROP_REST       = 1                           -- studs above the floor the handle rests
local DROP_GROUND_RAY = 15                          -- studs to look down for the floor

local FreezeService = {}

-- Per-player timestamp (os.clock) of the last accepted fire, for cooldown gating.
local lastFire: { [Player]: number } = {}

-- The single live dropped-gun pickup model, if one exists. Held tool and world
-- drop are mutually exclusive, so this enforces one gun at a time. (plan 5.5/5.6)
local currentDrop: Model? = nil

-- Phase 7 plugs in the human-team-win resolution here. (plan 7.3)
local alienFrozenHandler: ((shooter: Player, alien: Player) -> ())? = nil

-- Walk up from a hit part to the Player whose character it belongs to, if any.
local function playerFromHit(instance: Instance): Player?
	local current: Instance? = instance
	while current do
		if current:IsA("Model") then
			local player = Players:GetPlayerFromCharacter(current)
			if player then
				return player
			end
		end
		current = current.Parent
	end
	return nil
end

-- Resolve a landed, validated freeze by the TARGET's role (not its form). (5.3)
local function resolveFreeze(shooter: Player, target: Player)
	if PlayerRegistry.getRole(target) == Role.Alien then
		-- Alien frozen → human team wins. Hand off to Phase 7's win resolution.
		if alienFrozenHandler then
			alienFrozenHandler(shooter, target)
		else
			warn(`[FreezeService] Alien '{target.Name}' frozen by '{shooter.Name}' — no win handler wired (Phase 7)`)
		end
	else
		-- Wrong freeze: any non-Alien target eliminates BOTH shooter and target.
		SpectatorService.enter(target)
		SpectatorService.enter(shooter)
		print(`[FreezeService] Wrong freeze: '{shooter.Name}' froze '{target.Name}' — both eliminated`)
		-- These eliminations may have taken the last non-Alien. (plan 7.1)
		WinService.check()
	end
end

-- Find the Freeze Gun a player currently possesses — equipped in the character or
-- stowed in the Backpack — or nil if they are not the holder. (plan 5.5)
local function findGun(player: Player): Tool?
	local character = player.Character
	if character then
		local equipped = character:FindFirstChild(GUN_NAME)
		if equipped and equipped:IsA("Tool") then
			return equipped
		end
	end
	local backpack = player:FindFirstChildOfClass("Backpack")
	if backpack then
		local stowed = backpack:FindFirstChild(GUN_NAME)
		if stowed and stowed:IsA("Tool") then
			return stowed
		end
	end
	return nil
end

-- ProximityPrompt pickup: grant the gun only to an Alive Human. Rejects the Alien
-- (any form), Spectators, and anyone else. Removes the drop on grant. (plan 5.6)
local function handlePickup(player: Player)
	if currentDrop == nil then
		return  -- already taken / cleared — guards a double trigger
	end
	if PlayerRegistry.getState(player) ~= State.Alive then
		return
	end
	if PlayerRegistry.getRole(player) ~= Role.Human then
		return
	end
	currentDrop:Destroy()
	currentDrop = nil
	ToolService.grantFreezeGun(player)
end

-- The dropped gun as a world model, built from the real Freeze Gun's own parts. Only the
-- parts are kept: a Tool object left in the world could be auto-equipped by touch (even by
-- the Alien), whereas an anchored, non-touchable Model can only be taken via the prompt.
local function buildDropModel(): Model?
	local tool = ToolService.cloneTool(GUN_NAME)
	if not tool then
		return nil
	end
	local model = Instance.new("Model")
	model.Name = "DroppedFreezeGun"
	for _, child in tool:GetChildren() do
		child.Parent = model
	end
	tool:Destroy()

	local handle = model:FindFirstChild("Handle")
	if not handle or not handle:IsA("BasePart") then
		warn(`[FreezeService] '{GUN_NAME}' has no Handle part — cannot build the dropped gun`)
		model:Destroy()
		return nil
	end
	model.PrimaryPart = handle

	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") then
			descendant.Anchored   = true
			descendant.CanCollide = false
			descendant.CanTouch   = false
			descendant.CanQuery   = false -- never blocks a shot
		end
	end
	return model
end

-- Spawn the dropped gun (the real gun's model + ProximityPrompt + glow and sparkles so it
-- is easy to spot) resting on the floor under `position`. One drop at a time. (plan 5.5)
local function spawnDrop(position: Vector3)
	if currentDrop then
		currentDrop:Destroy()
		currentDrop = nil
	end

	local model = buildDropModel()
	local handle = if model then model.PrimaryPart else nil
	if not model or not handle then
		warn("[FreezeService] could not build the dropped gun — gun lost")
		return
	end

	-- Rest it on the floor below where the holder fell (ignoring characters).
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
	local result = Workspace:Raycast(position + Vector3.new(0, 2, 0), Vector3.new(0, -DROP_GROUND_RAY, 0), params)
	local floorY = if result then result.Position.Y else position.Y - 3
	model:PivotTo(CFrame.new(position.X, floorY + DROP_REST, position.Z))

	local prompt = Instance.new("ProximityPrompt")
	prompt.ActionText          = "Pick up"
	prompt.ObjectText          = GUN_NAME
	prompt.HoldDuration        = 0
	prompt.RequiresLineOfSight = false
	prompt.Triggered:Connect(handlePickup)
	prompt.Parent = handle

	local sparkles = Instance.new("ParticleEmitter")
	sparkles.Color          = ColorSequence.new(DROP_COLOR)
	sparkles.LightEmission  = 1
	sparkles.Size           = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.5),
		NumberSequenceKeypoint.new(1, 0),
	})
	sparkles.Transparency   = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0),
		NumberSequenceKeypoint.new(1, 1),
	})
	sparkles.Lifetime       = NumberRange.new(1, 1.6)
	sparkles.Speed          = NumberRange.new(2, 4)
	sparkles.EmissionDirection = Enum.NormalId.Top
	sparkles.SpreadAngle    = Vector2.new(35, 35)
	sparkles.Rate           = 30
	sparkles.Parent         = handle

	local glow = Instance.new("PointLight")
	glow.Color      = DROP_COLOR
	glow.Brightness = 2
	glow.Range      = 12
	glow.Parent     = handle

	-- Outline that is hidden behind walls, so it helps without acting as a wallhack.
	local outline = Instance.new("Highlight")
	outline.FillColor           = DROP_COLOR
	outline.FillTransparency    = 0.75
	outline.OutlineColor        = DROP_COLOR
	outline.OutlineTransparency = 0
	outline.DepthMode           = Enum.HighlightDepthMode.Occluded
	outline.Adornee             = model
	outline.Parent              = model

	model.Parent = Workspace
	currentDrop  = model
end

-- Before a holder is removed from play, drop the gun at their last position.
-- Covers abduction AND wrong-freeze — both route through SpectatorService.enter,
-- which invokes this via the before-enter hook while the character still exists.
-- (plan 5.5)
local function onBeforeEliminated(player: Player)
	local tool = findGun(player)
	if not tool then
		return  -- this player was not the holder
	end
	local character = player.Character
	local hrp = if character then character:FindFirstChild("HumanoidRootPart") else nil
	tool:Destroy()  -- the real Tool must never sit loose in the world
	if hrp and hrp:IsA("BasePart") then
		spawnDrop(hrp.Position)
	else
		warn(`[FreezeService] Gun holder '{player.Name}' eliminated with no HRP — gun lost`)
	end
end

-- A brief neon ball used for the muzzle flash and the impact flash.
local function spawnFlash(position: Vector3, diameter: number)
	local flash = Instance.new("Part")
	flash.Name         = "FreezeFlash"
	flash.Shape        = Enum.PartType.Ball
	flash.Size         = Vector3.new(diameter, diameter, diameter)
	flash.Color        = SHOT_COLOR
	flash.Material     = Enum.Material.Neon
	flash.Transparency = 0.3
	flash.Anchored     = true
	flash.CanCollide   = false
	flash.CanQuery     = false
	flash.CanTouch     = false
	flash.CastShadow   = false
	flash.CFrame       = CFrame.new(position)
	flash.Parent       = Workspace
	Debris:AddItem(flash, SHOT_VISIBLE_LIFE)
end

-- Cosmetic shot effect: a short-lived beam from the muzzle to where the shot ended, with
-- a flash at each end (bigger on a hit). Built on the server so every client sees it; it
-- is non-colliding and un-queryable so it can never block or alter another shot.
local function playShotEffect(origin: Vector3, endPoint: Vector3, hit: boolean)
	local delta = endPoint - origin
	local length = math.min(delta.Magnitude, SHOT_MAX_LENGTH)
	if length < 0.1 then
		return
	end
	local tip = origin + delta.Unit * length

	local beam = Instance.new("Part")
	beam.Name         = "FreezeBeam"
	beam.Size         = Vector3.new(0.25, 0.25, length)
	beam.Color        = SHOT_COLOR
	beam.Material     = Enum.Material.Neon
	beam.Transparency = 0.2
	beam.Anchored     = true
	beam.CanCollide   = false
	beam.CanQuery     = false
	beam.CanTouch     = false
	beam.CastShadow   = false
	beam.CFrame       = CFrame.lookAt(origin, tip) * CFrame.new(0, 0, -length / 2)
	beam.Parent       = Workspace
	Debris:AddItem(beam, SHOT_VISIBLE_LIFE)

	spawnFlash(origin, 1.2)
	spawnFlash(tip, if hit then 3 else 1.2)
	SoundEffects.playAt(SoundEffects.GUNSHOT, origin)
end

-- Handle one FreezeFired request. (5.2)
local function handleFire(shooter: Player, aimPoint: any)
	-- Shooter must be an Alive participant.
	if PlayerRegistry.getState(shooter) ~= State.Alive then
		return
	end

	-- Aim point must be a real Vector3 from the client.
	if typeof(aimPoint) ~= "Vector3" then
		return
	end
	local point = aimPoint :: Vector3

	-- Shooter must hold the Freeze Gun EQUIPPED (Tool parented into the character).
	-- This also validates the holder and gives us the muzzle; the Alien never
	-- holds the gun, so this doubles as the "Alien can't fire" guard.
	local character = shooter.Character
	if not character then
		return
	end
	local tool = character:FindFirstChild(GUN_NAME)
	if not tool or not tool:IsA("Tool") then
		return
	end
	local handle = tool:FindFirstChild("Handle")
	if not handle or not handle:IsA("BasePart") then
		return
	end

	-- Cooldown gate: reject while still cooling down.
	local now = os.clock()
	local last = lastFire[shooter]
	if last and (now - last) < GameConfig.FREEZE_COOLDOWN then
		return
	end
	-- Consumed on EVERY fire from here on, including misses and wall hits.
	lastFire[shooter] = now
	-- Tell the holder's HUD to start the cooldown indicator. (plan 5.4)
	FreezeCooldown:FireClient(shooter, GameConfig.FREEZE_COOLDOWN)

	-- Raycast from the muzzle toward the aim point. Exclude the shooter's own
	-- character so the muzzle doesn't self-hit; everything else (walls, players)
	-- can block, which is the line-of-sight check.
	local origin = handle.Position
	local delta = point - origin
	if delta.Magnitude == 0 then
		return
	end

	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { character }
	params.IgnoreWater = true

	local result = Workspace:Raycast(origin, delta.Unit * GameConfig.FREEZE_RANGE, params)
	-- Every shot is visible, whether it hits a player, a wall, or nothing.
	playShotEffect(origin, if result then result.Position else origin + delta.Unit * SHOT_MAX_LENGTH, result ~= nil)
	if not result then
		return  -- miss (cooldown already consumed)
	end

	local target = playerFromHit(result.Instance)
	if not target then
		return  -- hit a wall/world part: miss
	end
	if target == shooter then
		return  -- self-hit ignored
	end
	if PlayerRegistry.getState(target) ~= State.Alive then
		return  -- only Alive players can be frozen
	end

	-- Tell the shooter their shot connected (hit marker). Sent before resolving, since a
	-- wrong freeze removes the shooter from play. It does not say who or what was hit.
	FreezeHit:FireClient(shooter)
	resolveFreeze(shooter, target)
end

-- Phase 7 registers how an Alien freeze resolves into a human-team win. (plan 7.3)
function FreezeService.setAlienFrozenHandler(handler: (shooter: Player, alien: Player) -> ())
	alienFrozenHandler = handler
end

-- Remove any live dropped gun. RoundManager calls this on round end. (plan 5.7)
function FreezeService.clearDrop()
	if currentDrop then
		currentDrop:Destroy()
		currentDrop = nil
	end
end

-- Connect the fire handler. Called once from ServerBoot.
function FreezeService.start()
	FreezeFired.OnServerEvent:Connect(handleFire)
	SpectatorService.onBeforeEnter(onBeforeEliminated)
	Players.PlayerRemoving:Connect(function(player)
		lastFire[player] = nil
		onBeforeEliminated(player)  -- drop the gun if this player was the holder (plan 7.6)
	end)
end

return FreezeService
