--!strict
-- MusicController.luau  (ModuleScript, StarterPlayerScripts/Client)
-- Plays LobbyMusic (SoundService) while in the lobby and MatchMusic (SoundService) while a
-- match is in progress. Driven by RoundStateChanged; purely cosmetic and local to this client.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService      = game:GetService("SoundService")

local Remotes           = ReplicatedStorage:WaitForChild("Remotes")
local RoundStateChanged = Remotes:WaitForChild("RoundStateChanged") :: RemoteEvent

-- Phases during which a match is in progress; every other phase is lobby music.
local MATCH_PHASES: { [string]: boolean } = {
	Assigning   = true,
	Teleporting = true,
	Active      = true,
}

local MusicController = {}

local current: Sound? = nil

local function getTrack(name: string): Sound?
	local sound = SoundService:WaitForChild(name, 10)
	if sound and sound:IsA("Sound") then
		sound.Looped = true
		return sound
	end
	warn(`[MusicController] Sound '{name}' not found in SoundService`)
	return nil
end

-- Switch to `track`. No-op if it is already the playing track, because the Lobby phase is
-- re-broadcast every time the player count / countdown changes.
local function playTrack(track: Sound?)
	if track == current then
		return
	end
	if current then
		current:Stop()
	end
	current = track
	if track then
		track:Play()
	end
end

function MusicController.init()
	local lobbyMusic = getTrack("LobbyMusic")
	local matchMusic = getTrack("MatchMusic")

	-- Lobby music from the start; the first RoundStateChanged corrects it if needed.
	playTrack(lobbyMusic)

	RoundStateChanged.OnClientEvent:Connect(function(phase: string)
		playTrack(if MATCH_PHASES[phase] then matchMusic else lobbyMusic)
	end)
end

return MusicController
