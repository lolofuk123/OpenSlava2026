--!strict
-- ClientBoot.client.luau  (LocalScript, StarterPlayerScripts)
-- Entry point for all client-side systems.
-- Initialises modules in dependency order as they are written each phase.
--
-- Phase 3: boots HudController so RoleAssigned events display the role banner.
--          HudController also handles RoundStateChanged, FreezeCooldown,
--          AbductionOccurred, and RoundResult — all wired up now for later phases.

local Client = script.Parent:WaitForChild("Client")

local HudController       = require(Client:WaitForChild("HudController"))
local SpectatorController = require(Client:WaitForChild("SpectatorController"))

HudController.init()
SpectatorController.init()

-- Phase 4: InputController.init() will be added here.
