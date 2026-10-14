--!strict
-- HudController.luau  (ModuleScript, StarterPlayerScripts/Client)
-- Owns all in-game UI: role banner, round timer, freeze cooldown bar,
-- abduction notification, round-result screen, and spectator overlay.
-- All state is driven by RemoteEvents fired from the server.

local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService        = game:GetService("RunService")
local SoundService      = game:GetService("SoundService")
local TweenService      = game:GetService("TweenService")
local UserInputService  = game:GetService("UserInputService")
local Workspace         = game:GetService("Workspace")

local LocalPlayer = Players.LocalPlayer
local PlayerGui   = LocalPlayer:WaitForChild("PlayerGui") :: PlayerGui

local Remotes           = ReplicatedStorage:WaitForChild("Remotes")
local RoleAssigned      = Remotes:WaitForChild("RoleAssigned")      :: RemoteEvent
local RoundStateChanged = Remotes:WaitForChild("RoundStateChanged") :: RemoteEvent
local FreezeCooldown    = Remotes:WaitForChild("FreezeCooldown")    :: RemoteEvent
local FreezeHit         = Remotes:WaitForChild("FreezeHit")         :: RemoteEvent
local AbductionOccurred = Remotes:WaitForChild("AbductionOccurred") :: RemoteEvent
local RoundResult       = Remotes:WaitForChild("RoundResult")       :: RemoteEvent

local HudController = {}

-- ── Runtime state ─────────────────────────────────────────────────────────────
local roundEndTime:    number? = nil
local cooldownEndTime: number? = nil
local inLobby      = false  -- true while the server phase is Lobby (waiting / countdown)
local lobbyNeeded  = 0      -- players still needed before the start countdown begins
local localRole: string? = nil  -- own role this round; nil before assignment and for spectators
local introToken   = 0      -- bumped to cancel a pending intro fade-out when a newer one starts
local abducted     = false  -- the local player was abducted this round
local spectating   = false  -- the local player is currently a spectator (set by SpectatorController)
local crosshairOn  = false  -- the Freeze Gun crosshair is showing
local notifToken   = 0      -- bumped to cancel a pending notification fade-out
local bannerToken  = 0      -- same, for the spectator title
local aliveNames: { string } = {}  -- sorted names of everyone currently Alive
local FREEZE_COOLDOWN_SECS = 2.5  -- mirrors GameConfig; avoids requiring it on client
local INTRO_SECONDS        = 5    -- how long the round-start intro stays up
local INTRO_FADE_SECONDS   = 0.8
local BANNER_SECONDS       = 4    -- how long the "you were abducted/eliminated" title stays up
local NOTIF_FADE_SECONDS   = 0.3
local MAX_LISTED_SURVIVORS = 8    -- names shown on the result screen before "+N more"
local MAX_LISTED_ALIVE     = 8    -- names shown in the spectator's alive list before "+N more"
local NOTIF_COLOR_SELF     = Color3.fromRGB(255, 90, 90)   -- something happened to you
local NOTIF_COLOR_OTHER    = Color3.fromRGB(255, 210, 80)  -- something happened to someone else

-- ── UI references (populated by buildGui) ────────────────────────────────────
local gui:            ScreenGui
local roleBanner:     TextLabel
local timerLabel:     TextLabel
local lobbyLabel:     TextLabel
local cooldownFrame:  Frame
local cooldownBar:    Frame
local cooldownLabel:  TextLabel
local notifLabel:     TextLabel
local aliveLabel:      TextLabel
local aliveListFrame:  Frame
local aliveListLabel:  TextLabel
local spectatorBanner: Frame
local bannerTitle:     TextLabel
local bannerSub:       TextLabel
local crosshair:       Frame
local hitMarkerLines:  { Frame } = {}
local introFrame:     Frame
local introHeader:    TextLabel
local introTitle:     TextLabel
local introHint:      TextLabel
local resultFrame:    Frame
local resultStroke:   UIStroke
local resultTitle:    TextLabel
local resultSubtitle: TextLabel
local resultSurvivors: TextLabel
local spectatorFrame: Frame
local spectatorLabel: TextLabel
local spectatorCycleHandler: ((delta: number) -> ())? = nil

-- ── Helpers ───────────────────────────────────────────────────────────────────
local function label(parent: Instance, name: string, text: string,
		size: UDim2, pos: UDim2, fontSize: number, color: Color3?): TextLabel
	local l = Instance.new("TextLabel")
	l.Name                 = name
	l.Size                 = size
	l.Position             = pos
	l.BackgroundTransparency = 1
	l.Text                 = text
	l.TextSize             = fontSize
	l.Font                 = Enum.Font.GothamBold
	l.TextColor3           = color or Color3.fromRGB(255, 255, 255)
	l.TextStrokeColor3     = Color3.fromRGB(0, 0, 0)
	l.TextStrokeTransparency = 0.5
	l.TextScaled           = false
	l.Parent               = parent
	return l
end

local function formatTime(seconds: number): string
	local s = math.max(0, math.floor(seconds))
	return string.format("%d:%02d", math.floor(s / 60), s % 60)
end

-- ── GUI construction ──────────────────────────────────────────────────────────
local function buildGui()
	gui = Instance.new("ScreenGui")
	gui.Name          = "AlienAbductionHud"
	gui.ResetOnSpawn  = false
	gui.IgnoreGuiInset = true
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling

	-- Role banner — top-centre, shown during Active
	roleBanner = label(gui, "RoleBanner", "",
		UDim2.new(0.4, 0, 0, 38), UDim2.new(0.3, 0, 0, 10), 22)
	roleBanner.Visible = false

	-- Round timer — top-right
	timerLabel = label(gui, "Timer", "5:00",
		UDim2.new(0.12, 0, 0, 38), UDim2.new(0.86, 0, 0, 10), 22)
	timerLabel.Visible = false

	-- Lobby status — top-centre: "Waiting for players..." / start countdown
	lobbyLabel = label(gui, "LobbyStatus", "",
		UDim2.new(0.5, 0, 0, 44), UDim2.new(0.25, 0, 0, 20), 26)
	lobbyLabel.Visible = false

	-- Freeze cooldown — bottom-centre bar
	cooldownFrame = Instance.new("Frame")
	cooldownFrame.Name             = "CooldownFrame"
	cooldownFrame.Size             = UDim2.new(0.22, 0, 0, 26)
	cooldownFrame.Position         = UDim2.new(0.39, 0, 0.89, 0)
	cooldownFrame.BackgroundColor3 = Color3.fromRGB(40, 40, 40)
	cooldownFrame.BorderSizePixel  = 0
	cooldownFrame.Visible          = false
	cooldownFrame.Parent           = gui

	cooldownBar = Instance.new("Frame")
	cooldownBar.Name             = "CooldownBar"
	cooldownBar.Size             = UDim2.new(1, 0, 1, 0)
	cooldownBar.Position         = UDim2.new(0, 0, 0, 0)
	cooldownBar.BackgroundColor3 = Color3.fromRGB(0, 190, 255)
	cooldownBar.BorderSizePixel  = 0
	cooldownBar.Parent           = cooldownFrame

	cooldownLabel = label(cooldownFrame, "CooldownLabel", "READY",
		UDim2.new(1, 0, 1, 0), UDim2.new(0, 0, 0, 0), 13,
		Color3.fromRGB(0, 255, 120))
	cooldownLabel.ZIndex = 3

	-- Abduction notification — lower third, centre
	notifLabel = label(gui, "Notification", "",
		UDim2.new(0.5, 0, 0, 44), UDim2.new(0.25, 0, 0.74, 0), 18,
		Color3.fromRGB(255, 210, 80))
	notifLabel.TextWrapped = true
	notifLabel.Visible     = false

	-- Alive count — bottom-left corner (the top-left is covered by Roblox's own menu/chat UI)
	aliveLabel = label(gui, "AliveCount", "",
		UDim2.new(0, 240, 0, 30), UDim2.new(0, 14, 1, -14), 20)
	aliveLabel.AnchorPoint    = Vector2.new(0, 1)
	aliveLabel.TextXAlignment = Enum.TextXAlignment.Left
	aliveLabel.Visible = false

	-- Who is still alive — right side, shown to spectators only
	aliveListFrame = Instance.new("Frame")
	aliveListFrame.Name                   = "AliveListFrame"
	aliveListFrame.Size                   = UDim2.new(0, 210, 0, 0)
	aliveListFrame.Position               = UDim2.new(1, -224, 0, 60)
	aliveListFrame.AutomaticSize          = Enum.AutomaticSize.Y
	aliveListFrame.BackgroundColor3       = Color3.fromRGB(15, 15, 15)
	aliveListFrame.BackgroundTransparency = 0.35
	aliveListFrame.BorderSizePixel        = 0
	aliveListFrame.Visible                = false

	local alivePadding = Instance.new("UIPadding")
	alivePadding.PaddingTop    = UDim.new(0, 8)
	alivePadding.PaddingBottom = UDim.new(0, 8)
	alivePadding.PaddingLeft   = UDim.new(0, 10)
	alivePadding.PaddingRight  = UDim.new(0, 10)
	alivePadding.Parent        = aliveListFrame

	aliveListLabel = label(aliveListFrame, "AliveListLabel", "",
		UDim2.new(1, 0, 0, 0), UDim2.new(0, 0, 0, 0), 18)
	aliveListLabel.AutomaticSize  = Enum.AutomaticSize.Y
	aliveListLabel.TextWrapped    = true
	aliveListLabel.TextXAlignment = Enum.TextXAlignment.Left
	aliveListLabel.TextYAlignment = Enum.TextYAlignment.Top

	aliveListFrame.Parent = gui

	-- Spectator title — upper centre: "YOU WERE ABDUCTED" / "YOU WERE ELIMINATED" + a hint
	spectatorBanner = Instance.new("Frame")
	spectatorBanner.Name                   = "SpectatorBanner"
	spectatorBanner.AnchorPoint            = Vector2.new(0.5, 0.5)
	spectatorBanner.Size                   = UDim2.new(0.7, 0, 0.22, 0)
	spectatorBanner.Position               = UDim2.new(0.5, 0, 0.3, 0)
	spectatorBanner.BackgroundTransparency = 1
	spectatorBanner.Visible                = false
	spectatorBanner.Parent                 = gui

	bannerTitle = label(spectatorBanner, "BannerTitle", "",
		UDim2.new(1, 0, 0.55, 0), UDim2.new(0, 0, 0, 0), 52)
	bannerSub = label(spectatorBanner, "BannerSub", "",
		UDim2.new(0.8, 0, 0.35, 0), UDim2.new(0.1, 0, 0.58, 0), 22)
	bannerSub.TextWrapped = true

	-- Crosshair — follows the mouse while the Freeze Gun is equipped (the gun aims at the
	-- cursor). The red X inside it flashes when a shot connects.
	crosshair = Instance.new("Frame")
	crosshair.Name                   = "Crosshair"
	crosshair.AnchorPoint            = Vector2.new(0.5, 0.5)
	crosshair.Size                   = UDim2.fromOffset(40, 40)
	crosshair.BackgroundTransparency = 1
	crosshair.ZIndex                 = 10
	crosshair.Visible                = false

	local function crosshairBar(position: UDim2, w: number, h: number)
		local bar = Instance.new("Frame")
		bar.Position         = position
		bar.Size             = UDim2.fromOffset(w, h)
		bar.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
		bar.BorderSizePixel  = 0
		bar.ZIndex           = 10
		local outline = Instance.new("UIStroke")
		outline.Color     = Color3.fromRGB(0, 0, 0)
		outline.Thickness = 1
		outline.Parent    = bar
		bar.Parent = crosshair
	end
	crosshairBar(UDim2.new(0.5, -1, 0, 5),    2, 9) -- top
	crosshairBar(UDim2.new(0.5, -1, 0, 26),   2, 9) -- bottom
	crosshairBar(UDim2.new(0, 5, 0.5, -1),    9, 2) -- left
	crosshairBar(UDim2.new(0, 26, 0.5, -1),   9, 2) -- right
	crosshairBar(UDim2.new(0.5, -1, 0.5, -1), 2, 2) -- centre dot

	for _, angle in { 45, -45 } do
		local line = Instance.new("Frame")
		line.Name                   = "HitMarker"
		line.AnchorPoint            = Vector2.new(0.5, 0.5)
		line.Position               = UDim2.new(0.5, 0, 0.5, 0)
		line.Size                   = UDim2.fromOffset(20, 3)
		line.Rotation               = angle
		line.BackgroundColor3       = Color3.fromRGB(255, 70, 70)
		line.BackgroundTransparency = 1
		line.BorderSizePixel        = 0
		line.ZIndex                 = 11
		line.Parent                 = crosshair
		table.insert(hitMarkerLines, line)
	end

	crosshair.Parent = gui

	-- Round-start intro — upper centre: "ROUND START", big role title, one-line hint
	introFrame = Instance.new("Frame")
	introFrame.Name                   = "IntroFrame"
	introFrame.AnchorPoint            = Vector2.new(0.5, 0.5)
	introFrame.Size                   = UDim2.new(0.7, 0, 0.3, 0)
	introFrame.Position               = UDim2.new(0.5, 0, 0.3, 0)
	introFrame.BackgroundTransparency = 1
	introFrame.Visible                = false
	introFrame.Parent                 = gui

	introHeader = label(introFrame, "IntroHeader", "ROUND START",
		UDim2.new(1, 0, 0.2, 0), UDim2.new(0, 0, 0, 0), 26, Color3.fromRGB(255, 210, 80))
	introTitle = label(introFrame, "IntroTitle", "",
		UDim2.new(1, 0, 0.45, 0), UDim2.new(0, 0, 0.2, 0), 60)
	introHint = label(introFrame, "IntroHint", "",
		UDim2.new(0.8, 0, 0.3, 0), UDim2.new(0.1, 0, 0.68, 0), 22)
	introHint.TextWrapped = true

	-- Round result — centre overlay; colours are set per outcome when it is shown
	resultFrame = Instance.new("Frame")
	resultFrame.Name               = "ResultFrame"
	resultFrame.Size               = UDim2.new(0.5, 0, 0.36, 0)
	resultFrame.Position           = UDim2.new(0.25, 0, 0.32, 0)
	resultFrame.BackgroundColor3   = Color3.fromRGB(15, 15, 15)
	resultFrame.BackgroundTransparency = 0.1
	resultFrame.BorderSizePixel    = 0
	resultFrame.Visible            = false

	local resultCorner = Instance.new("UICorner")
	resultCorner.CornerRadius = UDim.new(0, 14)
	resultCorner.Parent       = resultFrame

	resultStroke = Instance.new("UIStroke")
	resultStroke.Thickness = 3
	resultStroke.Parent    = resultFrame

	resultFrame.Parent = gui

	resultTitle = label(resultFrame, "ResultTitle", "",
		UDim2.new(1, 0, 0.36, 0), UDim2.new(0, 0, 0.06, 0), 48)
	resultSubtitle = label(resultFrame, "ResultSubtitle", "",
		UDim2.new(0.9, 0, 0.2, 0), UDim2.new(0.05, 0, 0.42, 0), 22, Color3.fromRGB(225, 225, 225))
	resultSubtitle.TextWrapped = true
	resultSurvivors = label(resultFrame, "ResultSurvivors", "",
		UDim2.new(0.9, 0, 0.28, 0), UDim2.new(0.05, 0, 0.64, 0), 20, Color3.fromRGB(190, 190, 190))
	resultSurvivors.TextWrapped = true

	-- Spectator panel — bottom-centre: [<]  Now spectating <name>  [>]
	spectatorFrame = Instance.new("Frame")
	spectatorFrame.Name               = "SpectatorFrame"
	spectatorFrame.AnchorPoint        = Vector2.new(0.5, 1)
	spectatorFrame.Size               = UDim2.new(0, 440, 0, 56)
	spectatorFrame.Position           = UDim2.new(0.5, 0, 1, -24)
	spectatorFrame.BackgroundColor3   = Color3.fromRGB(15, 15, 15)
	spectatorFrame.BackgroundTransparency = 0.35
	spectatorFrame.BorderSizePixel    = 0
	spectatorFrame.Visible            = false
	spectatorFrame.Parent             = gui

	spectatorLabel = label(spectatorFrame, "SpectatorLabel", "Now spectating —",
		UDim2.new(1, -120, 1, 0), UDim2.new(0, 60, 0, 0), 18)

	local function arrowButton(name: string, text: string, x: UDim2, delta: number)
		local b = Instance.new("TextButton")
		b.Name             = name
		b.AnchorPoint      = Vector2.new(0, 0.5)
		b.Size             = UDim2.new(0, 44, 0, 44)
		b.Position         = x
		b.BackgroundColor3 = Color3.fromRGB(45, 45, 45)
		b.BorderSizePixel  = 0
		b.Text             = text
		b.TextSize         = 24
		b.Font             = Enum.Font.GothamBold
		b.TextColor3       = Color3.fromRGB(255, 255, 255)
		b.AutoButtonColor  = true
		b.Activated:Connect(function()
			if spectatorCycleHandler then
				spectatorCycleHandler(delta)
			end
		end)
		b.Parent = spectatorFrame
	end
	arrowButton("PrevButton", "<", UDim2.new(0, 8, 0.5, 0), -1)
	arrowButton("NextButton", ">", UDim2.new(1, -52, 0.5, 0), 1)

	gui.Parent = PlayerGui
end

-- ── Public: spectator overlay control (called by SpectatorController) ─────────
function HudController.setSpectatorTarget(target: Player?, allTargets: { Player }, index: number)
	if target then
		spectatorLabel.Text = `Now spectating {target.Name} ({index}/{#allTargets})`
		spectatorFrame.Visible = true
	else
		spectatorFrame.Visible = false
	end
end

function HudController.showSpectatorFrame(visible: boolean)
	spectatorFrame.Visible = visible
	if not visible then
		spectatorLabel.Text = "Now spectating —"
	end
end

-- SpectatorController registers how the arrow buttons cycle the camera
-- (delta = -1 previous, +1 next). Registered rather than required to avoid a
-- HudController <-> SpectatorController require cycle.
function HudController.setSpectatorCycleHandler(handler: (delta: number) -> ())
	spectatorCycleHandler = handler
end

-- ── Role text / colour / hint lookup ──────────────────────────────────────────
local ROLE_TEXT: { [string]: string } = {
	["Alien"]     = "You are the ALIEN",
	["Scientist"] = "You are the SCIENTIST",
	["Human"]     = "You are a HUMAN",
}
local ROLE_COLOR: { [string]: Color3 } = {
	["Alien"]     = Color3.fromRGB(80, 255, 80),
	["Scientist"] = Color3.fromRGB(80, 180, 255),
	["Human"]     = Color3.fromRGB(255, 255, 255),
}
local ROLE_HINT: { [string]: string } = {
	["Alien"]     = "Press 1 to equip your staff — it reveals your alien form. Click near a player to abduct them. Don't get frozen!",
	["Scientist"] = "Press 1 to equip the Freeze Gun, then click to shoot the Alien. Careful: freezing a human eliminates you both!",
	["Human"]     = "Survive! Work out who the Alien is. If the Scientist falls, grab the dropped Freeze Gun.",
}

-- ── Outcome text / colour / sound lookup ──────────────────────────────────────
local OUTCOME_TITLE: { [string]: string } = {
	["AlienWin"] = "ALIEN WINS",
	["HumanWin"] = "HUMANS WIN",
	["Draw"]     = "DRAW",
}
local OUTCOME_SUBTITLE: { [string]: string } = {
	["AlienWin"] = "All humans have been abducted.",
	["HumanWin"] = "The alien has been frozen!",
	["Draw"]     = "Time ran out — no winner.",
}
local OUTCOME_COLOR: { [string]: Color3 } = {
	["AlienWin"] = Color3.fromRGB(80, 255, 80),
	["HumanWin"] = Color3.fromRGB(80, 180, 255),
	["Draw"]     = Color3.fromRGB(210, 210, 210),
}
local OUTCOME_BACKGROUND: { [string]: Color3 } = {
	["AlienWin"] = Color3.fromRGB(8, 40, 12),
	["HumanWin"] = Color3.fromRGB(8, 28, 52),
	["Draw"]     = Color3.fromRGB(38, 38, 42),
}
-- Optional stings: if a Sound with this name exists in SoundService it plays on the result.
local OUTCOME_STING: { [string]: string } = {
	["AlienWin"] = "AlienWinSting",
	["HumanWin"] = "HumanWinSting",
	["Draw"]     = "DrawSting",
}

-- Fade a set of labels out over INTRO_FADE_SECONDS, then hide their frame. Does nothing if
-- `isCurrent` reports that a newer showing has replaced this one.
local function fadeOutThenHide(frame: Frame, labels: { TextLabel }, isCurrent: () -> boolean)
	if not isCurrent() then
		return
	end
	local fade = TweenInfo.new(INTRO_FADE_SECONDS)
	for _, l in labels do
		TweenService:Create(l, fade, { TextTransparency = 1, TextStrokeTransparency = 1 }):Play()
	end
	task.delay(INTRO_FADE_SECONDS, function()
		if isCurrent() then
			frame.Visible = false
		end
	end)
end

-- ── Internal: round-start intro ───────────────────────────────────────────────
local function hideIntro()
	introToken += 1
	introFrame.Visible = false
end

-- "ROUND START", plus the big role title and hint when this player has a role. Holds for
-- INTRO_SECONDS, then fades out. Each call cancels the previous call's pending fade.
local function showIntro()
	introToken += 1
	local token = introToken
	local role = localRole

	introTitle.Text       = if role then (ROLE_TEXT[role] or role) else ""
	introTitle.TextColor3 = if role then (ROLE_COLOR[role] or Color3.fromRGB(255, 255, 255)) else Color3.fromRGB(255, 255, 255)
	introHint.Text        = if role then (ROLE_HINT[role] or "") else ""
	for _, l in { introHeader, introTitle, introHint } do
		l.TextTransparency       = 0
		l.TextStrokeTransparency = 0.5
	end
	introFrame.Visible = true

	task.delay(INTRO_SECONDS, function()
		fadeOutThenHide(introFrame, { introHeader, introTitle, introHint }, function()
			return token == introToken
		end)
	end)
end

-- ── Internal: round result ────────────────────────────────────────────────────
local function formatSurvivors(names: { string }?): string
	if not names or #names == 0 then
		return "No survivors"
	end
	local shown: { string } = {}
	for i = 1, math.min(#names, MAX_LISTED_SURVIVORS) do
		shown[i] = names[i]
	end
	local text = "Survivors: " .. table.concat(shown, ", ")
	if #names > MAX_LISTED_SURVIVORS then
		text ..= `  (+{#names - MAX_LISTED_SURVIVORS} more)`
	end
	return text
end

local function playSting(outcome: string)
	local name = OUTCOME_STING[outcome]
	local sound = if name then SoundService:FindFirstChild(name) else nil
	if sound and sound:IsA("Sound") then
		sound:Play()
	end
end

-- ── Internal: brief on-screen notification ────────────────────────────────────
-- Fades in, holds, fades out; coloured by who it concerns. A newer notification replaces
-- an older one and cancels its pending fade-out.
local function showNotif(text: string, duration: number, color: Color3)
	notifToken += 1
	local token = notifToken

	notifLabel.Text                   = text
	notifLabel.TextColor3             = color
	notifLabel.TextTransparency       = 1
	notifLabel.TextStrokeTransparency = 1
	notifLabel.Visible                = true
	local fade = TweenInfo.new(NOTIF_FADE_SECONDS)
	TweenService:Create(notifLabel, fade, { TextTransparency = 0, TextStrokeTransparency = 0.5 }):Play()

	task.delay(duration, function()
		if token ~= notifToken then
			return
		end
		TweenService:Create(notifLabel, fade, { TextTransparency = 1, TextStrokeTransparency = 1 }):Play()
		task.delay(NOTIF_FADE_SECONDS, function()
			if token == notifToken then
				notifLabel.Visible = false
			end
		end)
	end)
end

-- ── Internal: spectator title and alive list ──────────────────────────────────
-- Title text for the local player becoming a spectator. Abducted comes from the abduction
-- event; otherwise someone who had a role this round was eliminated (wrong freeze); someone
-- with no role joined mid-round.
local function spectatorBannerContent(): (string, string, Color3)
	if abducted then
		return "YOU WERE ABDUCTED", "Watch the rest of the round. Use the arrows to switch players.", Color3.fromRGB(80, 255, 80)
	elseif localRole ~= nil then
		return "YOU WERE ELIMINATED", "Watch the rest of the round. Use the arrows to switch players.", Color3.fromRGB(255, 90, 90)
	end
	return "SPECTATING", "A round is in progress. You'll join the next one.", Color3.fromRGB(255, 255, 255)
end

local function showSpectatorBanner()
	bannerToken += 1
	local token = bannerToken
	local title, sub, color = spectatorBannerContent()

	bannerTitle.Text       = title
	bannerTitle.TextColor3 = color
	bannerSub.Text         = sub
	for _, l in { bannerTitle, bannerSub } do
		l.TextTransparency       = 0
		l.TextStrokeTransparency = 0.5
	end
	spectatorBanner.Visible = true

	task.delay(BANNER_SECONDS, function()
		fadeOutThenHide(spectatorBanner, { bannerTitle, bannerSub }, function()
			return token == bannerToken
		end)
	end)
end

-- "Still alive:" panel for spectators; hidden for everyone else.
local function refreshAliveList()
	local shown: { string } = {}
	for i = 1, math.min(#aliveNames, MAX_LISTED_ALIVE) do
		shown[i] = aliveNames[i]
	end
	local text = "Still alive:\n" .. table.concat(shown, "\n")
	if #aliveNames > MAX_LISTED_ALIVE then
		text ..= `\n+{#aliveNames - MAX_LISTED_ALIVE} more`
	end
	aliveListLabel.Text    = text
	aliveListFrame.Visible = spectating and #aliveNames > 0
end

-- Red X flash on the crosshair when a shot connects.
local function flashHitMarker()
	local tween = TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	for _, line in hitMarkerLines do
		line.BackgroundTransparency = 0
		line.Size = UDim2.fromOffset(20, 3)
		TweenService:Create(line, tween, {
			BackgroundTransparency = 1,
			Size = UDim2.fromOffset(34, 3),
		}):Play()
	end
end

-- ── Public: alive list, spectator state, crosshair ────────────────────────────
-- SpectatorController passes every Alive player here each time it refreshes. Drives the
-- "Players alive: N" counter (hidden when no round is running) and the spectators' list.
function HudController.setAlivePlayers(alive: { Player })
	aliveNames = {}
	for _, player in alive do
		table.insert(aliveNames, player.Name)
	end
	table.sort(aliveNames)
	aliveLabel.Text    = `Players alive: {#aliveNames}`
	aliveLabel.Visible = #aliveNames > 0
	refreshAliveList()
end

-- SpectatorController reports when the local player enters or leaves spectator view.
function HudController.onSpectatingChanged(on: boolean)
	if spectating == on then
		return
	end
	spectating = on
	if on then
		hideIntro()
		HudController.setCrosshairVisible(false)
		showSpectatorBanner()
	else
		bannerToken += 1
		spectatorBanner.Visible = false
	end
	refreshAliveList()
end

-- InputController shows the crosshair while the Freeze Gun is equipped. It replaces the
-- system cursor, since the gun fires at the cursor position.
function HudController.setCrosshairVisible(on: boolean)
	crosshairOn = on and not spectating
	crosshair.Visible = crosshairOn
	UserInputService.MouseIconEnabled = not crosshairOn
end

-- ── Internal: lobby status text ──────────────────────────────────────────────
local function updateLobbyLabel()
	local endTime = roundEndTime
	if not inLobby then
		lobbyLabel.Visible = false
	elseif lobbyNeeded > 0 then
		lobbyLabel.Text    = `Waiting for players... ({lobbyNeeded} more needed)`
		lobbyLabel.Visible = true
	elseif endTime ~= nil then
		local remaining    = math.max(0, math.ceil(endTime - Workspace:GetServerTimeNow()))
		lobbyLabel.Text    = `Round starting in {remaining}...`
		lobbyLabel.Visible = true
	else
		lobbyLabel.Visible = false
	end
end

-- ── Internal: phase change handler ───────────────────────────────────────────
local function onPhaseChanged(phase: string, endTime: number?, needed: number?)
	roundEndTime = endTime
	inLobby      = phase == "Lobby"
	lobbyNeeded  = needed or 0
	updateLobbyLabel()
	if phase ~= "Active" then
		HudController.setCrosshairVisible(false)
	end

	if phase == "Active" then
		timerLabel.Visible  = true
		resultFrame.Visible = false
		showIntro()
	elseif phase == "Ending" then
		timerLabel.Visible = false
		hideIntro()
	elseif phase == "Lobby" or phase == "Intermission" then
		timerLabel.Visible    = false
		roleBanner.Visible    = false
		cooldownFrame.Visible = false
		cooldownEndTime       = nil
		localRole             = nil
		abducted              = false
		hideIntro()
	else
		-- Assigning, Teleporting
		timerLabel.Visible = false
		hideIntro()
	end
end

-- ── Internal: heartbeat tick ─────────────────────────────────────────────────
local function tick()
	-- Lobby start countdown
	if inLobby then
		updateLobbyLabel()
	end

	-- Crosshair follows the cursor
	if crosshairOn then
		local mouse = UserInputService:GetMouseLocation()
		crosshair.Position = UDim2.fromOffset(mouse.X, mouse.Y)
	end

	-- Timer countdown
	if timerLabel.Visible and roundEndTime ~= nil then
		local remaining = (roundEndTime :: number) - Workspace:GetServerTimeNow()
		timerLabel.Text = formatTime(remaining)
	end

	-- Cooldown bar
	if cooldownFrame.Visible then
		if cooldownEndTime == nil then
			cooldownBar.Size           = UDim2.new(1, 0, 1, 0)
			cooldownBar.BackgroundColor3 = Color3.fromRGB(0, 190, 255)
			cooldownLabel.Text         = "READY"
			cooldownLabel.TextColor3   = Color3.fromRGB(0, 255, 120)
		else
			local remaining = (cooldownEndTime :: number) - Workspace:GetServerTimeNow()
			if remaining <= 0 then
				cooldownEndTime              = nil
				cooldownBar.Size             = UDim2.new(1, 0, 1, 0)
				cooldownBar.BackgroundColor3 = Color3.fromRGB(0, 190, 255)
				cooldownLabel.Text           = "READY"
				cooldownLabel.TextColor3     = Color3.fromRGB(0, 255, 120)
			else
				local frac                   = remaining / FREEZE_COOLDOWN_SECS
				cooldownBar.Size             = UDim2.new(math.clamp(frac, 0, 1), 0, 1, 0)
				cooldownBar.BackgroundColor3 = Color3.fromRGB(255, 80, 80)
				cooldownLabel.Text           = string.format("%.1fs", remaining)
				cooldownLabel.TextColor3     = Color3.fromRGB(255, 255, 255)
			end
		end
	end
end

-- ── Public init ───────────────────────────────────────────────────────────────
function HudController.init()
	buildGui()

	-- Phase / timer
	RoundStateChanged.OnClientEvent:Connect(function(phase: string, endTime: number?, needed: number?)
		onPhaseChanged(phase, endTime, needed)
	end)

	-- Role banner (own role only; server never sends another player's role)
	RoleAssigned.OnClientEvent:Connect(function(role: string)
		localRole             = role
		roleBanner.Text       = ROLE_TEXT[role] or role
		roleBanner.TextColor3 = ROLE_COLOR[role] or Color3.fromRGB(255, 255, 255)
		roleBanner.Visible    = true
	end)

	-- Freeze cooldown indicator — payload is the cooldown duration in seconds
	FreezeCooldown.OnClientEvent:Connect(function(duration: number)
		cooldownEndTime       = Workspace:GetServerTimeNow() + duration
		cooldownFrame.Visible = true
	end)

	-- Abduction notification
	AbductionOccurred.OnClientEvent:Connect(function(victim: Player?)
		if victim == LocalPlayer then
			abducted = true
			if spectating then
				showSpectatorBanner() -- the spectator title may have appeared before this event; correct it
			end
			showNotif("You have been ABDUCTED!", 5, NOTIF_COLOR_SELF)
		elseif victim ~= nil then
			showNotif(victim.Name .. " was abducted!", 3, NOTIF_COLOR_OTHER)
		else
			showNotif("A player was abducted!", 3, NOTIF_COLOR_OTHER)
		end
	end)

	-- Shot connected: flash the hit marker
	FreezeHit.OnClientEvent:Connect(flashHitMarker)

	-- Round result screen (auto-hides after 8s so it doesn't linger into next round)
	RoundResult.OnClientEvent:Connect(function(outcome: string, survivors: { string }?)
		local color = OUTCOME_COLOR[outcome] or Color3.fromRGB(255, 255, 255)
		resultTitle.Text             = OUTCOME_TITLE[outcome] or outcome
		resultTitle.TextColor3       = color
		resultSubtitle.Text          = OUTCOME_SUBTITLE[outcome] or ""
		resultSurvivors.Text         = formatSurvivors(survivors)
		resultFrame.BackgroundColor3 = OUTCOME_BACKGROUND[outcome] or Color3.fromRGB(15, 15, 15)
		resultStroke.Color           = color
		resultFrame.Visible          = true
		playSting(outcome)
		task.delay(8, function()
			resultFrame.Visible = false
		end)
	end)

	-- Heartbeat drives timer and cooldown bar every frame
	RunService.Heartbeat:Connect(tick)
end

return HudController
