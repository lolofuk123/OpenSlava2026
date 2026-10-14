# implementation_plan.md — Alien Abduction

Phased build plan derived from [specs.md](specs.md). Phases are ordered so each one is independently testable in Roblox Studio before moving on. Check a box when the task is done and verified.

Conventions (from CLAUDE.md / specs §2): `.luau`, `--!strict`, `task.*` (never `wait()`), services via `game:GetService()`, `Instance.new()` then set `Parent` last, server-authoritative. Test by executing code in Studio via the `Roblox_Studio` MCP server — Studio must be open and the plugin connected.

**Complexity legend** (model guidance per task):
- 🧠 = complex — non-trivial logic, state/concurrency, server validation, or character/appearance manipulation. Prefer a stronger model (e.g. Opus).
- ⚡ = straightforward — boilerplate, config, wiring, simple UI. Fine with a lighter model (e.g. Sonnet).

---

## Phase 1 — Project scaffolding & shared foundation

Goal: folder structure, config, enums, type definitions, and remotes exist and load without errors. No gameplay yet.

- [x] 1.1 ⚡ Create `ReplicatedStorage/Shared/` and `ReplicatedStorage/Remotes/` folders.
- [x] 1.2 ⚡ Create `ServerScriptService/Server/` folder.
- [x] 1.3 ⚡ Create `StarterPlayer/StarterPlayerScripts/Client/` folder.
- [x] 1.4 ⚡ Write `Shared/GameConfig.luau` with all constants from specs §11 (`MIN_PLAYERS=3`, `ROUND_SECONDS=300`, `INTERMISSION_SECONDS=10`, `FREEZE_COOLDOWN=2.5`, `ALIEN_COUNT=1`, `SCIENTIST_COUNT=1`, `ABDUCT_RANGE=5`, `FREEZE_RANGE=1000`).
- [x] 1.5 ⚡ Write `Shared/GameEnums.luau` exporting `Role` (`Alien`/`Scientist`/`Human`/`None`), `RoundPhase` (`Lobby`/`Assigning`/`Teleporting`/`Active`/`Ending`/`Intermission`), `PlayerState` (`Lobby`/`Alive`/`Spectator`).
- [x] 1.6 🧠 Write `Shared/RoundState.luau` with side-effect-free type definitions (participant record, round snapshot). Must pass `--!strict`.
- [x] 1.7 ⚡ Write a boot step (in a server script) that creates all RemoteEvents/RemoteFunctions from specs §12 under `ReplicatedStorage/Remotes` at startup: `RoundStateChanged`, `RoleAssigned`, `TransformToggled`, `AlienAttacked`, `FreezeFired`, `FreezeCooldown`, `AbductionOccurred`, `RoundResult` (RemoteEvents) and `SpectatorTargets` (RemoteFunction).
- [x] 1.8 ⚡ Set `Players.CharacterAutoLoads = false` at server boot (specs §9).
- [x] 1.9 ⚡ Build placeholder geometry: a **lobby area** with spawn(s) and a separate **map area** with spawn(s), hazard-free.

### Test in Studio (Phase 1)
- Run the place; confirm no script errors in the Output window.
- Confirm all 9 remotes exist under `ReplicatedStorage/Remotes` with correct class (RemoteEvent vs RemoteFunction).
- Confirm `require(GameConfig)` returns every constant with the correct value.
- Confirm players do **not** auto-spawn (CharacterAutoLoads off) — a joining player has no character until the server loads one.

---

## Phase 2 — Round lifecycle & teleport/spawning

Goal: the round state machine cycles through phases on a stubbed roster (no real roles yet), and teleports characters between lobby and map.

- [x] 2.1 🧠 Write `Server/PlayerRegistry.luau` tracking per-player `PlayerState`, `Role`, and roster membership; helpers to query `Alive` players and the current roster.
- [x] 2.2 ⚡ Write `Server/TeleportService.luau`: load a character at a map spawn, move characters lobby↔map via `CFrame`, and lobby-spawn on join.
- [x] 2.3 🧠 Write `Server/RoundManager.luau` state machine per specs §4: Lobby wait (`>= MIN_PLAYERS`), Assigning (stub: just mark players `Alive` + build roster), Teleporting (load characters at map, no tools yet), Active (start timer), Ending, Intermission (`task.wait(INTERMISSION_SECONDS)`), loop.
- [x] 2.4 🧠 Implement the server round timer using `os.clock`/`task.delay`; broadcast phase + absolute end timestamp (`workspace:GetServerTimeNow()`) via `RoundStateChanged`.
- [x] 2.5 🧠 Re-check player count on join/leave to start/hold rounds; fix the roster at Assigning (mid-round joiners excluded).
- [x] 2.6 ⚡ Handle roster player disconnect: remove from `Alive` and roster (specs §3.3).
- [x] 2.7 ⚡ On Ending: teleport everyone to lobby, reset roles/states to Lobby.

### Test in Studio (Phase 2)
- Start a 2-player local test: with only 2 players the round must **not** start (stays Lobby).
- Add a 3rd player (or simulate): round advances Assigning → Teleporting (characters appear at map spawns) → Active.
- Confirm `RoundStateChanged` fires with each phase and an end timestamp; verify the timer ends the round after `ROUND_SECONDS` (temporarily lower it to ~15s to test fast).
- Confirm Ending teleports everyone back to lobby, then after 10s the cycle restarts.
- Disconnect a player mid-round; confirm they leave the roster and the cycle stays consistent.

---

## Phase 3 — Role assignment

Goal: each round secretly assigns 1 Alien + 1 Scientist; each player learns only their own role.

- [x] 3.1 ⚡ Write `Server/RoleService.luau`: from the Lobby-state players, pick 1 Alien and 1 different Scientist with `Random.new()`; rest are Human. Role-repeat allowed (no anti-repeat).
- [x] 3.2 ⚡ Wire RoleService into RoundManager's Assigning phase (replace the Phase-2 stub).
- [x] 3.3 ⚡ Send each player their own role via `RoleAssigned` (targeted); never broadcast others' roles.
- [x] 3.4 ⚡ Reset all roles to `None` at round end.
- [x] 3.5 ⚡ Minimal client receiver for `RoleAssigned` that prints/logs the local player's role (temporary, for verification).

### Test in Studio (Phase 3)
- Run a 3+ player test; confirm exactly one Alien and one Scientist are assigned, everyone else Human.
- Confirm each client receives **only** its own role (inspect each client's log; no client should be able to read another's role from replicated data).
- Run several rounds; confirm assignment is randomized and role-repeat can occur.

---

## Phase 4 — Alien mechanics (Transform + abduction)

Goal: the Alien can toggle form via the Transform tool and abduct in-range players with an explicit attack.

- [x] 4.1 ⚡ Create the fixed **Alien model** asset (green body parts, single appearance).
- [x] 4.2 ⚡ Grant the **Transform** `Tool` to the Alien when the character loads (specs §4 step 3 ordering).
- [x] 4.3 🧠 Write `Server/AlienService.luau`: on equip → capture original `HumanoidDescription`, swap character to Alien model, preserve position/velocity; on unequip → restore original appearance. No cooldown.
- [x] 4.4 ⚡ Client `InputController` sends `TransformToggled` on tool equip/unequip and `AlienAttacked` on `Tool.Activated` (attack).
- [x] 4.5 🧠 Server abduction handler on `AlienAttacked`: validate actor is Alien in equipped form, target is another `Alive` player (never self), target HRP within `ABDUCT_RANGE` of Alien HRP; on success set target → `Spectator` and fire `AbductionOccurred`.
- [x] 4.6 ⚡ Reject attacks when unequipped (normal form) or out of range.

### Test in Studio (Phase 4)
- As the Alien, equip the Transform tool → confirm the character switches to the green Alien model at the same position; unequip → confirm exact original avatar is restored.
- Confirm toggling has no cooldown and is not a teleport.
- Equip + attack a player standing within 5 studs → target is abducted (enters Spectator). Attack a player >5 studs away → nothing happens.
- Confirm attacking while in normal (unequipped) form does nothing, and the Alien cannot abduct itself.

---

## Phase 5 — Scientist / Freeze Gun

Goal: the Freeze Gun fires via server raycast with cooldown, resolves freezes by role, handles wrong-freeze elimination, and drops/pickup works for Humans only.

- [x] 5.1 ⚡ Grant the **Freeze Gun** `Tool` to the Scientist when the character loads.
- [x] 5.2 🧠 Write `Server/FreezeService.luau` fire handler on `FreezeFired`: reject if on cooldown; server raycast from muzzle toward client aim point, length `FREEZE_RANGE`, validate line-of-sight and target `Alive`; start `FREEZE_COOLDOWN` on every fire (hit or miss).
- [x] 5.3 🧠 Resolve by target **Role** (not form): target is Alien → Alien frozen → trigger human-team win (hook into Phase 7); target is Human → eliminate both shooter and target → Spectator; ignore self-hits.
- [x] 5.4 ⚡ Send `FreezeCooldown` (targeted) to the current holder for the HUD indicator.
- [x] 5.5 🧠 On holder elimination (abduction or wrong-freeze): spawn the **dropped-gun world part with `ProximityPrompt`** at last position; the real `Tool` never sits loose in the world.
- [x] 5.6 🧠 Pickup handler: grant the `Freeze Gun` `Tool` only to an `Alive` **Human**; reject Alien (any form) and Spectators; remove the world part on grant. Enforce a single gun/drop at a time.
- [x] 5.7 ⚡ Remove any dropped gun/world part on round end (specs §4 step 6).

### Test in Studio (Phase 5)
- As Scientist, fire at the Alien (even while the Alien is disguised in human form) → Alien freezes, round moves toward human-team win.
- Fire at a Human → both shooter and that Human are eliminated to Spectator; round continues.
- Fire repeatedly → confirm 2.5s cooldown enforced server-side and the miss/wall shot still consumes cooldown.
- Eliminate the gun holder → confirm the gun drops as a prompt part; a Human can pick it up, the Alien cannot, and a Spectator cannot.
- Confirm only one gun exists at a time and it's removed at round end.

---

## Phase 6 — Spectator mode

Goal: abducted/eliminated/mid-round-join players spectate alive players and cannot affect the round.

- [x] 6.1 🧠 Extend `Server/SpectatorService.luau`: on entering `Spectator`, remove/freeze the character out of play and disable input server-side; mid-round joiners enter Spectator immediately.
- [x] 6.2 ⚡ Implement `SpectatorTargets` RemoteFunction returning the current `Alive` player list.
- [x] 6.3 🧠 Write client `SpectatorController.luau`: camera cycling (next/previous) across alive players; refresh the list when it changes.
- [x] 6.4 ⚡ Ensure spectators cannot move, interact, or communicate with the live round.
- [x] 6.5 ⚡ On round end, return spectators to Lobby state like everyone else.

### Test in Studio (Phase 6)
- Get abducted → confirm immediate Spectator entry, no movement/interaction, and camera shows an alive player.
- Cycle next/previous → camera moves across all currently-alive players only.
- Join mid-round → immediately a Spectator; confirmed added to next round's assignment.
- When a spectated player is abducted, confirm the spectator list updates and the camera retargets.

---

## Phase 7 — Win conditions & round-end integration

Goal: all win conditions and edge cases resolve correctly and atomically; round end cleans up fully.

- [x] 7.1 🧠 Write the server win-check (specs §10), invoked after every abduction, freeze hit, and participant leave, and on timer expiry.
- [x] 7.2 ⚡ Condition 1 — Alien wins when **no `Alive` non-Alien roster players remain**.
- [x] 7.3 ⚡ Condition 2 — human team wins when the Alien is frozen; winners = all surviving `Alive` non-Alien players (abducted/eliminated excluded).
- [x] 7.4 ⚡ Condition 3 — Draw on timer expiry with no winner.
- [x] 7.5 🧠 Edge: Alien disconnects mid-round → round ends immediately, no winner.
- [x] 7.6 ⚡ Edge: Scientist leaves before firing → gun drops, round continues.
- [x] 7.7 ⚡ Edge: count drops below `MIN_PLAYERS` mid-round → round continues and resolves naturally.
- [x] 7.8 🧠 Atomicity: once phase is `Ending`, all further win-checks are no-ops (single-threaded ordering).
- [x] 7.9 ⚡ Broadcast outcome via `RoundResult`; ensure Ending strips tools and removes any dropped gun.

### Test in Studio (Phase 7)
- Alien abducts all non-Aliens → Alien-wins fires and round ends.
- Scientist/Human freezes the Alien → human-team-win fires; confirm only surviving non-Aliens are listed as winners.
- Let the timer expire with both sides alive → Draw.
- Disconnect the Alien mid-round → immediate no-winner end.
- Force two win triggers in the same frame (abduct last Human + freeze Alien together) → exactly one outcome is declared.
- After any end, confirm tools stripped, dropped gun removed, everyone back in lobby.

---

## Phase 8 — HUD & client feedback polish

Goal: players see their role, the round timer, freeze cooldown, and outcome clearly.

- [x] 8.1 ⚡ Write `Client/HudController.luau`: role banner on `RoleAssigned`; round countdown from the `RoundStateChanged` end timestamp using `workspace:GetServerTimeNow()`.
- [x] 8.2 ⚡ Freeze cooldown indicator (bar/timer) driven by `FreezeCooldown`, shown to the current gun holder.
- [x] 8.3 ⚡ Abduction feedback via `AbductionOccurred` (VFX/notification).
- [x] 8.4 ⚡ Round result screen on `RoundResult` (Alien win / human team win / Draw).
- [x] 8.5 ⚡ Spectator HUD hint (who you're viewing, cycle controls).

### Test in Studio (Phase 8)
- Confirm each player sees their own role banner at round start and nothing about others.
- Confirm the countdown matches the server timer with no drift across clients.
- Confirm the cooldown indicator appears for the gun holder and clears after 2.5s.
- Confirm the result screen shows the correct outcome for Alien win, human-team win, and Draw.
- Confirm spectator HUD shows the viewed player and cycle controls.

---

## Cross-cutting checklist (verify before "done")

- [ ] C.1 ⚡ No `wait()` anywhere; all delays use `task.*`.
- [ ] C.2 ⚡ No client is ever sent another player's role; all effects server-validated.
- [ ] C.3 ⚡ All services pass `--!strict`.
- [ ] C.4 ⚡ `Instance.new()` sets `Parent` last; services accessed via `game:GetService()`.
- [ ] C.5 🧠 Full multi-round soak test: 4+ players, several consecutive rounds, mixed outcomes, joins/leaves mid-round, no errors or stuck phases.
