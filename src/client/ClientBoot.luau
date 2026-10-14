--!strict
-- ClientBoot.luau  (LocalScript, StarterPlayerScripts)
-- Entry point for all client-side systems. Requires and initialises each
-- controller in dependency order; controllers wire their own RemoteEvent
-- listeners and do no work until events fire.

local Client = script.Parent:WaitForChild("Client")

local HudController       = require(Client:WaitForChild("HudController"))
local SpectatorController = require(Client:WaitForChild("SpectatorController"))
local InputController     = require(Client:WaitForChild("InputController"))
local MusicController     = require(Client:WaitForChild("MusicController"))

HudController.init()
SpectatorController.init()
InputController.init()
MusicController.init()
