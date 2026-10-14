--!strict
-- ServerBoot.luau  (Script, runs once on server start)
-- 1. Disables default character auto-loading (server owns all spawning, specs §9).
-- 2. Creates all RemoteEvents and RemoteFunctions under ReplicatedStorage/Remotes (specs §12).

local Players             = game:GetService("Players")
local ReplicatedStorage   = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

-- ── 1.8  Disable auto-spawn ───────────────────────────────────────────────────
Players.CharacterAutoLoads = false

-- ── 1.7  Create remotes ───────────────────────────────────────────────────────
local Remotes = ReplicatedStorage:WaitForChild("Remotes")

local EVENTS: { string } = {
	"RoundStateChanged",   -- S→C  phase + end timestamp
	"RoleAssigned",        -- S→C  targeted: tells a player their own role
	"TransformToggled",    -- C→S  Alien equip/unequip (form swap)
	"AlienAttacked",       -- C→S  Alien attack intent (server validates range + target)
	"FreezeFired",         -- C→S  Scientist/holder fire intent (aim point for raycast)
	"FreezeCooldown",      -- S→C  targeted: cooldown state for HUD indicator
	"FreezeHit",           -- S→C  targeted: tells the shooter their shot connected (hit marker)
	"AbductionOccurred",   -- S→C  broadcast: VFX + spectator enrollment trigger
	"RoundResult",         -- S→C  broadcast: winner/draw announcement
}

local FUNCTIONS: { string } = {
	"SpectatorTargets",    -- C→S  fetch current Alive player list for camera cycling
}

for _, name in EVENTS do
	if not Remotes:FindFirstChild(name) then
		local re = Instance.new("RemoteEvent")
		re.Name = name
		re.Parent = Remotes
	end
end

for _, name in FUNCTIONS do
	if not Remotes:FindFirstChild(name) then
		local rf = Instance.new("RemoteFunction")
		rf.Name = name
		rf.Parent = Remotes
	end
end

-- ── Phase 4.3  Alien form-swap handler (TransformToggled) ──────────────────────
-- (The Transform and Freeze Gun tools are authored in ServerStorage/Tools.)
local Server = ServerScriptService:WaitForChild("Server")
local AlienService = require(Server:WaitForChild("AlienService"))
AlienService.start()

-- ── Phase 6  Spectator targets handler (before the round loop runs) ────────────
local SpectatorService = require(Server:WaitForChild("SpectatorService"))
SpectatorService.start()

-- ── Phase 5  Freeze Gun fire handler ──────────────────────────────────────────
local FreezeService = require(Server:WaitForChild("FreezeService"))
FreezeService.start()

-- ── Phase 2  Start the round lifecycle (after remotes exist) ───────────────────
local RoundManager = require(Server:WaitForChild("RoundManager"))
RoundManager.start()
