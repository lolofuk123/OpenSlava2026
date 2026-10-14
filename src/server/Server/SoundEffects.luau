--!strict
-- SoundEffects.luau  (ModuleScript, ServerScriptService/Server)
-- Plays one of the template Sounds stored in SoundService from a point in the world, so
-- every nearby client hears it positionally. Cosmetic only.

local Debris       = game:GetService("Debris")
local SoundService = game:GetService("SoundService")
local Workspace    = game:GetService("Workspace")

local EMITTER_LIFETIME = 5 -- seconds before the temporary emitter part is cleaned up

local SoundEffects = {}

-- Template names in SoundService.
SoundEffects.GUNSHOT   = "Laser Gunshot"
SoundEffects.ABDUCTION = "alien isolation accept beep"

-- Play a copy of the named SoundService sound at `position`. The template is never played
-- directly, so overlapping plays don't cut each other off.
function SoundEffects.playAt(soundName: string, position: Vector3)
	local template = SoundService:FindFirstChild(soundName)
	if not template or not template:IsA("Sound") then
		warn(`[SoundEffects] Sound '{soundName}' not found in SoundService`)
		return
	end

	local emitter = Instance.new("Part")
	emitter.Name         = "SoundEmitter"
	emitter.Size         = Vector3.new(0.2, 0.2, 0.2)
	emitter.Transparency = 1
	emitter.Anchored     = true
	emitter.CanCollide   = false
	emitter.CanQuery     = false
	emitter.CanTouch     = false
	emitter.CastShadow   = false
	emitter.CFrame       = CFrame.new(position)

	local sound = template:Clone()
	sound.Parent = emitter
	emitter.Parent = Workspace
	sound:Play()
	Debris:AddItem(emitter, EMITTER_LIFETIME)
end

return SoundEffects
