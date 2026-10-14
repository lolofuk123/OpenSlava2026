--!strict
-- AlienService.luau  (ModuleScript, ServerScriptService/Server)
-- Manages the Alien's Transform tool, form-swap, and abduction. (specs §6, plan 4.2–4.6)
-- Phase 4.2: grant the Transform tool after the character loads.
-- Phase 4.3: equip → recolour the character's MeshParts green; unequip → restore their
--            original colours. In place and instant; no cooldown.
-- Phase 4.5/4.6: on AlienAttacked, abduct the nearest Alive player within range,
--            but only while in equipped (Alien) form.

local Debris               = game:GetService("Debris")
local Players             = game:GetService("Players")
local ReplicatedStorage   = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Shared     = ReplicatedStorage:WaitForChild("Shared")
local GameEnums  = require(Shared:WaitForChild("GameEnums"))
local GameConfig = require(Shared:WaitForChild("GameConfig"))

local Server           = ServerScriptService:WaitForChild("Server")
local PlayerRegistry   = require(Server:WaitForChild("PlayerRegistry"))
local ToolService      = require(Server:WaitForChild("ToolService"))
local SpectatorService = require(Server:WaitForChild("SpectatorService"))
local WinService       = require(Server:WaitForChild("WinService"))
local LabTubeService   = require(Server:WaitForChild("LabTubeService"))
local SoundEffects     = require(Server:WaitForChild("SoundEffects"))

local Remotes           = ReplicatedStorage:WaitForChild("Remotes")
local TransformToggled  = Remotes:WaitForChild("TransformToggled")  :: RemoteEvent
local AlienAttacked     = Remotes:WaitForChild("AlienAttacked")     :: RemoteEvent
local AbductionOccurred = Remotes:WaitForChild("AbductionOccurred") :: RemoteEvent

local Role  = GameEnums.Role
local State = GameEnums.PlayerState

local ALIEN_GREEN    = Color3.fromRGB(0, 170, 0)
local GLOW_GREEN     = Color3.fromRGB(80, 255, 80) -- brighter green for the abduction flash
local TRANSFORM_TOOL = "Transform" -- name of the tool in ServerStorage/Tools
local FLASH_SECONDS  = 0.8         -- how long the tool stays lit after a successful abduction

type AlienState = {
	transformed: boolean,                     -- true while in equipped (green) Alien form
	originalColors: { [MeshPart]: Color3 },   -- each body part's colour before transforming
	lastAttack: number,                       -- os.clock() of the last accepted attack, for the cooldown
}

local AlienService = {}

-- Per-Alien state for the current round, re-captured in grantTransformTool each round.
local aliens: { [Player]: AlienState } = {}

-- Turn the character green by recolouring its MeshParts in place (direct children of the
-- character only, so accessories are untouched). The original colours are remembered so
-- untransforming can put them back exactly. Nothing is rebuilt or re-applied, so the
-- equipped tool and its grip weld are never disturbed. (specs §6, plan 4.3)
local function paintAlien(state: AlienState, character: Model)
	table.clear(state.originalColors)
	for _, part in character:GetChildren() do
		if part:IsA("MeshPart") then
			state.originalColors[part] = part.Color
			part.Color = ALIEN_GREEN
		end
	end
end

local function restoreColors(state: AlienState)
	for part, color in state.originalColors do
		part.Color = color -- harmless if the part has since been destroyed
	end
	table.clear(state.originalColors)
end

-- Make the Alien swing the equipped tool. The default character Animate script watches the
-- equipped Tool for a "toolanim" StringValue and plays its built-in slash animation (on the
-- owner's client, so it replicates smoothly to everyone); the script then removes the value.
-- Debris is only a safety net for characters without that script. (specs §6)
local function swingTool(character: Model)
	local tool = character:FindFirstChild(TRANSFORM_TOOL)
	if not tool or not tool:IsA("Tool") then
		return
	end
	local cue = Instance.new("StringValue")
	cue.Name = "toolanim"
	cue.Value = "Slash"
	cue.Parent = tool
	Debris:AddItem(cue, 1)
end

-- Neon-green flash on the Alien's tool after a successful abduction: its parts turn neon
-- green (then are restored), with a green light and a short burst of sparks from the
-- crystal. Built on the server so every client sees it. Cosmetic only.
local function playAbductionEffect(character: Model)
	local tool = character:FindFirstChild(TRANSFORM_TOOL)
	if not tool or not tool:IsA("Tool") then
		return
	end

	local original: { [BasePart]: { color: Color3, material: Enum.Material } } = {}
	for _, part in tool:GetDescendants() do
		if part:IsA("BasePart") then
			original[part] = { color = part.Color, material = part.Material }
			part.Color = GLOW_GREEN
			part.Material = Enum.Material.Neon
		end
	end
	task.delay(FLASH_SECONDS, function()
		for part, look in original do
			if part.Parent then
				part.Color = look.color
				part.Material = look.material
			end
		end
	end)

	local anchor = tool:FindFirstChild("Crystal") or tool:FindFirstChild("Handle")
	if not anchor or not anchor:IsA("BasePart") then
		return
	end

	local light = Instance.new("PointLight")
	light.Color = GLOW_GREEN
	light.Brightness = 4
	light.Range = 14
	light.Parent = anchor
	Debris:AddItem(light, FLASH_SECONDS)

	local sparks = Instance.new("ParticleEmitter")
	sparks.Color = ColorSequence.new(GLOW_GREEN)
	sparks.LightEmission = 1
	sparks.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.6),
		NumberSequenceKeypoint.new(1, 0),
	})
	sparks.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0),
		NumberSequenceKeypoint.new(1, 1),
	})
	sparks.Lifetime = NumberRange.new(0.4, 0.7)
	sparks.Speed = NumberRange.new(4, 9)
	sparks.SpreadAngle = Vector2.new(180, 180)
	sparks.Rate = 120
	sparks.Parent = anchor
	task.delay(0.2, function() -- a burst, not a stream: stop emitting, let the particles fade
		sparks.Enabled = false
	end)
	Debris:AddItem(sparks, FLASH_SECONDS + 0.5)
end

-- Clone the Transform Tool into the Alien's Backpack and reset their Alien state.
-- Called after the character loads. (plan 4.2)
function AlienService.grantTransformTool(player: Player)
	if not player.Character then
		warn(`[AlienService] '{player.Name}' has no character — cannot set up Alien`)
		return
	end
	local backpack = player:WaitForChild("Backpack", 5)
	if not backpack then
		warn(`[AlienService] No Backpack for '{player.Name}' — cannot grant Transform tool`)
		return
	end

	aliens[player] = {
		transformed = false,
		originalColors = {},
		lastAttack = -math.huge,
	}

	local tool = ToolService.cloneTool(TRANSFORM_TOOL)
	if tool then
		tool.Parent = backpack
	end
end

-- Equip/unequip toggle from the Alien's client. `transformed` is true on equip
-- (become the green Alien) and false on unequip (restore the avatar). (specs §6, plan 4.3)
local function onTransformToggled(player: Player, transformed: boolean)
	if typeof(transformed) ~= "boolean" then
		return
	end
	local state = aliens[player]
	if not state then
		return -- not this round's Alien
	end
	-- Server-authoritative guards: still the Alien, still Alive. (specs §2)
	if PlayerRegistry.getRole(player) ~= Role.Alien then
		return
	end
	if PlayerRegistry.getState(player) ~= State.Alive then
		return
	end
	-- Ignore a request for the form we are already in.
	if transformed == state.transformed then
		return
	end

	local character = player.Character
	if not character then
		return
	end

	if transformed then
		paintAlien(state, character)
	else
		restoreColors(state)
	end
	state.transformed = transformed
end

-- Attack intent from the Alien's client. The server picks the target: the nearest
-- Alive player (never self) whose HRP is within ABDUCT_RANGE of the Alien's HRP.
-- Only works while equipped (Alien form); rejected otherwise. (specs §6, plan 4.5 / 4.6)
local function onAlienAttacked(player: Player)
	local state = aliens[player]
	if not state then
		return -- not this round's Alien
	end
	-- Server-authoritative guards: must be the Alien, Alive, and in equipped form.
	if PlayerRegistry.getRole(player) ~= Role.Alien then
		return
	end
	if PlayerRegistry.getState(player) ~= State.Alive then
		return
	end
	if not state.transformed then
		warn(`[AlienService] '{player.Name}' attack rejected: not in Alien form (equip the Transform tool first)`)
		return -- normal form cannot attack (plan 4.6)
	end

	-- Cooldown gate. Consumed by every attack that gets this far, hit or miss, so spamming
	-- clicks can't be used to scan for targets.
	local now = os.clock()
	if now - state.lastAttack < GameConfig.ABDUCT_COOLDOWN then
		return
	end
	state.lastAttack = now

	local character = player.Character
	local alienHrp = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not character or not alienHrp then
		return
	end
	local alienPos = alienHrp.Position

	-- Swing on every accepted attack, whether or not anyone is in range.
	swingTool(character)

	-- Closest Alive player within range wins; the client never names a target. (specs §6)
	local target: Player? = nil
	local bestDist = GameConfig.ABDUCT_RANGE
	local nearestAny = math.huge -- nearest Alive player regardless of range, for the log below
	for _, other in PlayerRegistry.getAlive() do
		if other ~= player then
			local otherChar = other.Character
			local otherHrp = otherChar and otherChar:FindFirstChild("HumanoidRootPart") :: BasePart?
			if otherHrp then
				local dist = (otherHrp.Position - alienPos).Magnitude
				nearestAny = math.min(nearestAny, dist)
				if dist <= bestDist then
					target = other
					bestDist = dist
				end
			end
		end
	end

	if not target then
		if nearestAny == math.huge then
			warn(`[AlienService] '{player.Name}' attack: no other Alive players with a character`)
		else
			warn(`[AlienService] '{player.Name}' attack: nearest Alive player is {string.format("%.1f", nearestAny)} studs away (range {GameConfig.ABDUCT_RANGE})`)
		end
		return -- nobody in range (plan 4.6)
	end

	-- Abduct: target → Spectator, then notify clients for VFX/feedback. (specs §6, plan 4.5)
	playAbductionEffect(character)
	-- Cosmetics read the victim's position, so they run before enter() destroys the character.
	local victimCharacter = target.Character
	local victimHrp = victimCharacter and victimCharacter:FindFirstChild("HumanoidRootPart")
	if victimHrp and victimHrp:IsA("BasePart") then
		SoundEffects.playAt(SoundEffects.ABDUCTION, victimHrp.Position)
	end
	LabTubeService.spawnAt(target)
	SpectatorService.enter(target)
	AbductionOccurred:FireAllClients(target)
	-- Re-evaluate win conditions: this may have taken the last non-Alien. (plan 7.1)
	WinService.check()
end

-- Wire the TransformToggled / AlienAttacked handlers and per-player cleanup.
-- Called once from ServerBoot.
function AlienService.start()
	TransformToggled.OnServerEvent:Connect(onTransformToggled)
	AlienAttacked.OnServerEvent:Connect(onAlienAttacked)
	Players.PlayerRemoving:Connect(function(player: Player)
		aliens[player] = nil
	end)
end

return AlienService
