# specs.md — Alien Abduction (Technical Specification)

Written for: the engineer(s) implementing this game in Roblox Studio (Luau + Rojo-style `server`/`client`/`shared` boundaries).

Derived from [game_rules.md](game_rules.md). The rules file is the source of truth for *what the game does*; this file defines *how it is built*. All implementation decisions where the rules were silent have been confirmed with the designer and are recorded in section 14.

---

## 1. Overview

A single-place, round-based social-deduction game. Each round the server secretly assigns one **Alien** and one **Scientist**; all other players are **Humans**. The Alien wins by abducting everyone; the Scientist and surviving Humans win by freezing the Alien. Rounds run on a 5-minute timer with a lobby/intermission between them.

The game is **server-authoritative**. All role assignment, state transitions, hit validation, win-condition checks, and teleports happen on the server. Clients only render state and send intent (equip/unequip, attack, fire).

**Role, not appearance, decides everything.** The Alien can toggle back to a normal avatar to blend in. All freeze/abduction resolution keys off the server-side **Role**, never the current visual form — the Scientist can freeze the Alien even while it looks like a Human, and a disguised Alien is still the Alien for every win check.

---

## 2. Architecture & Boundaries

Per project conventions (`.luau`, `--!strict`, `task.*`, no deprecated APIs, RemoteEvents in `ReplicatedStorage`):

```
ReplicatedStorage/
  Shared/
    GameConfig.luau        -- all tunable constants (section 11)
    GameEnums.luau         -- Role, RoundPhase, PlayerState enums
    RoundState.luau        -- shared type definitions (side-effect free)
  Remotes/                 -- RemoteEvents / RemoteFunctions (created at boot)

ServerScriptService/
  Server/
    RoundManager.luau      -- round lifecycle state machine (section 4)
    RoleService.luau       -- role assignment (section 5)
    AlienService.luau      -- Transform tool + abduction logic (section 6)
    FreezeService.luau     -- Freeze Gun + freeze resolution (section 7)
    SpectatorService.luau  -- spectator enrollment (section 8)
    TeleportService.luau   -- lobby <-> map spawning
    PlayerRegistry.luau    -- per-player round state tracking

StarterPlayer/StarterPlayerScripts/
  Client/
    HudController.luau      -- round timer, cooldown indicator, role banner
    SpectatorController.luau-- camera cycling for spectators
    InputController.luau    -- transform toggle / attack / fire intent -> remotes
```

**Boundary rules:**
- Role assignment, abduction, freeze resolution, win checks, and the round timer live **only on the server**. Clients never learn another player's role.
- A player learns **only their own role** (sent to that client at round start for HUD/banner purposes).
- Tools (Transform, Freeze Gun) send *intent* to the server; the server validates and applies effects. The client never decides a hit landed.

---

## 3. Core State Model

### 3.1 Round phases (`RoundPhase`)
`Lobby → Assigning → Teleporting → Active → Ending → (Intermission) → Lobby`

- **Lobby** — waiting for enough players; free-roam.
- **Assigning** — server picks Alien + Scientist.
- **Teleporting** — all participants moved into the map.
- **Active** — gameplay enabled; round timer running.
- **Ending** — win/timeout resolved, result broadcast.
- **Intermission** — 10s in lobby, then back to Assigning.

### 3.2 Per-player state (`PlayerState`)
- `Lobby` — in lobby, not in an active round.
- `Alive` — participating in the current round.
- `Spectator` — abducted, eliminated, or joined mid-round.

Each player also carries a `Role` (`Alien` | `Scientist` | `Human` | `None`) valid only for the current round, reset at round end.

### 3.3 Participant roster
The **roster** is the set of players assigned roles when the round starts (phase `Assigning`). It is fixed for the round: mid-round joiners are **not** added (they spectate until the next round). A roster player who **disconnects** mid-round is removed from both the `Alive` set and the roster, so win checks only ever consider currently-connected roster players.

---

## 4. Round Lifecycle (RoundManager state machine)

1. **Lobby wait** — Remain in Lobby until `#aliveEligible >= MIN_PLAYERS` (3). Re-check on player join/leave.
2. **Assigning** — Call RoleService to pick Alien + Scientist from Lobby players; everyone else Human. Set each participant `PlayerState = Alive`.
3. **Teleporting** — Because `CharacterAutoLoads` is disabled (section 9), the server first **loads each participant's character at a map spawn**, then grants tools (Transform to Alien, Freeze Gun to Scientist) once the character exists.
4. **Active** — Start the 5-minute round timer. Enable abduction/freeze. Broadcast phase to clients.
5. **Win check** — Evaluated on every relevant event (abduction, freeze hit, player leave) and on timer expiry. See section 10.
6. **Ending** — Broadcast result (Alien win / human team win / Draw). Strip tools from players **and remove any Freeze Gun dropped in the map**. Teleport everyone to lobby. Reset roles and states to Lobby. Once the phase is `Ending`, further win-checks are skipped (section 10).
7. **Intermission** — `task.wait(INTERMISSION_SECONDS)` (10s), then go to step 1.

The round timer and intermission use `task.delay` / `os.clock` deltas on the server; the server is authoritative for time. The server sends clients an **absolute end timestamp** taken from `workspace:GetServerTimeNow()`; each client renders `remaining = endTime − workspace:GetServerTimeNow()`, avoiding clock skew.

---

## 5. Role Assignment (RoleService)

- Input: list of players in Lobby state (≥ 3).
- Randomly select **1 Alien** and **1 different Scientist**; all remaining become Human.
- Use a server-side RNG (`Random.new()`).
- Send each player a private "your role is X" message (own role only).
- **Role repeat is allowed** — no anti-repeat weighting; a player may be Alien (or Scientist) in consecutive rounds.

---

## 6. Alien (AlienService)

- Alien receives a **Transform** tool (a standard `Tool`). The tool has **two distinct input channels**, which must not be conflated:
  - **Equip / unequip** (the `Tool`'s equipped state) → **toggles form**. Equipping swaps the character to the Alien model; unequipping swaps back to the normal avatar. This is the blend-in mechanic and has **no cooldown**.
  - **Activate** (`Tool.Activated` — a click/tap *while equipped*) → **attack** (see Abduction below). Activating while unequipped does nothing.
- **Unequipped form** → normal avatar appearance (indistinguishable from Human).
- **Equipped form** → server swaps the character to the fixed **Alien model** (green body parts, single fixed appearance — no skins/variants). The Transform tool stays equipped in this form so the Alien can activate it to attack.
  - **Appearance restore:** the server **captures the player's original appearance (HumanoidDescription) at round start** and restores it on untransform, so toggling back reproduces the exact pre-round avatar. Position/velocity are preserved across the swap so the toggle isn't a teleport.
- **Abduction:** triggered by an **explicit attack input** (`Tool.Activated` while in Alien form), **not** by passive touch. The target is only abducted if they are **within range**.
  - Detection: client sends an attack intent via `AlienAttacked` (C→S). The server validates: the actor is the Alien in **equipped** (Alien-form) state; the target is another player (never self) who is `Alive`; and the target's HumanoidRootPart is within `ABDUCT_RANGE` studs of the Alien's HumanoidRootPart (server-side distance check — the client's claim is not trusted).
  - Effect: on a valid in-range attack, the target → `Spectator` immediately (section 8).
- Abduction is only possible while **equipped** (in Alien form). In normal form the Alien cannot attack/abduct.
- The Alien **cannot** use the Freeze Gun, and **cannot pick up** a dropped one (enforced server-side — see 7).

## 7. Scientist / Freeze Gun (FreezeService)

- Scientist receives a **Freeze Gun** tool.
- **Infinite ammo**, **2.5s cooldown** between shots, enforced server-side (client shows the indicator but cannot bypass it). The cooldown is consumed on **every fire**, including shots that hit nothing or hit a wall — there is no free "scanning." A fire request received while on cooldown is rejected server-side.
- On-cooldown HUD indicator (bar/timer) shown to the current gun holder.
- **Visible tell by design:** like the Alien's transform, *equipping* the Freeze Gun makes it visible in-hand and reveals the holder. This is intentional and symmetric — the gun is a normal visible `Tool`; do not hide it. The holder manages the risk of drawing it, just as the Alien manages the risk of transforming.
- **Range:** unlimited line-of-sight (raycast length `FREEZE_RANGE`, default effectively unlimited / map-spanning). The only gating is a clear raycast to the target.
- Firing resolves by the target's **Role** (not its visual form — a disguised Alien still counts as the Alien):
  - **Target is the Alien** → Alien frozen → round ends, **human team wins** (see section 10).
  - **Target is a Human** (wrong freeze) → **both** the shooter and the wrongly-frozen Human are eliminated → both enter `Spectator`. Round continues.
  - The shooter **cannot target themselves** (self-hits are ignored, no cooldown penalty beyond the normal fire cost).
- **Gun drops on holder elimination:** if the current gun holder is eliminated (by abduction *or* by a wrong freeze), the Freeze Gun drops at their last position as a pickup. Only a surviving **Human** can pick it up and continue.
  - **Pickup mechanism (not a free-floating `Tool`).** A `Tool` left in the workspace auto-equips to *any* Humanoid that touches it, which would let the Alien grab it. To enforce Human-only pickup, the drop is represented as a **world part with a `ProximityPrompt`** (or a server-gated touch part). On pickup request the server checks the requester is an `Alive` **Human**; if so it grants the actual `Freeze Gun` `Tool` and removes the world part. Requests from the **Alien** (any form) or Spectators are rejected. The `Tool` itself never sits loose in the world.
  - Only **one** Freeze Gun / drop exists at a time; it is removed from the world on round end (section 4 step 6).
- **Hit detection is raycast**: the server casts a ray from the muzzle toward a client-supplied aim point, then validates line-of-sight and that the hit target is `Alive`. The client never decides the hit; the server resolves it.

## 8. Spectator Mode (SpectatorService)

- Entered automatically the instant a player is abducted, eliminated, or joins mid-round.
- Spectators **cannot** move, interact, or communicate with the live round (character removed or frozen out of play; input disabled server-side).
- Spectators **can cycle** between currently-`Alive` players' camera views (next/previous), handled by SpectatorController on the client, with the alive-player list supplied by the server.
- On round end, spectators return to Lobby state like everyone else.

## 9. Teleport / Spawning (TeleportService)

- Single place (no `TeleportService` cross-place jumps) — "teleport" means moving characters between the **lobby area** and the **map area** within the place via spawn locations / `CFrame` sets.
- Round start: all participants → map spawns.
- Round end: all players (alive + spectators) → lobby spawns.
- **Server owns all spawning:** `Players.CharacterAutoLoads` is **disabled**; the server decides when and where each character loads. This prevents Roblox's default respawn from dropping a player into an undefined state mid-round.
- **Environmental death mid-round:** there is no combat damage in this game, but a roster player could still die (fall off the map, etc.). An `Alive` roster player who dies by any means other than abduction/wrong-freeze is treated as **eliminated → Spectator** (triggers a win check like any other elimination); their character is not auto-respawned until the next round. The map should otherwise be built hazard-free.

---

## 10. Win Conditions (evaluated server-side)

Checked after every abduction, every freeze hit, every participant leave, and on timer expiry. **The first win-triggering event to be processed decides the round.** The server is single-threaded, so events resolve in order; as soon as a check sets the phase to `Ending`, all subsequent win-checks are no-ops (prevents a double-resolution when two events land in the same frame, e.g. the Alien abducts the last Human the same moment it is frozen).

1. **Alien wins** — **no `Alive` non-Alien roster players remain** (every Human + the Scientist/gun-holder has been abducted, eliminated, or disconnected). Stating it as "no `Alive` non-Aliens left" rather than "all are Spectators" correctly covers disconnects (section 3.3).
2. **Human team wins** — the Alien is frozen by a Freeze Gun hit. The winners are **all surviving (`Alive`) non-Alien players** — whoever is left, whether or not the original Scientist is among them. Abducted/eliminated players do **not** count as winners.
3. **Draw / timeout** — 5-minute timer expires with no winner → round ends, no winner.

Edge cases to handle:
- **Alien leaves mid-round** → the **round ends immediately** (no winner); everyone (alive + spectators) is teleported back to the lobby, then normal intermission.
- **Scientist leaves before firing** → gun drops at last position (per 7) so a Human can continue; no special end.
- **Player count drops below `MIN_PLAYERS` mid-round** → the round **continues** (the 3-player minimum gates round *start* only) and resolves naturally via conditions 1–3. If only the Alien remains `Alive`, condition 1 fires (Alien wins).
- A **mid-round joiner** is a Spectator and does not count toward win checks until the next round.

---

## 11. Configuration Constants (GameConfig.luau)

| Constant | Value | Source |
|---|---|---|
| `MIN_PLAYERS` | 3 | rules (Confirmed Parameters) |
| `ROUND_SECONDS` | 300 (5 min) | rules |
| `INTERMISSION_SECONDS` | 10 | rules |
| `FREEZE_COOLDOWN` | 2.5 s | rules |
| `ALIEN_COUNT` | 1 | rules |
| `SCIENTIST_COUNT` | 1 | rules |
| `ABDUCT_RANGE` | 5 studs | design decision — abduction max range, HRP-to-HRP (section 6) |
| `FREEZE_RANGE` | 1000 studs | design decision — Freeze Gun raycast length; effectively unlimited line-of-sight (section 7) |

All timing uses `task.wait` / `task.delay`; never `wait()`.

---

## 12. Remotes (ReplicatedStorage/Remotes)

| Name | Type | Direction | Purpose |
|---|---|---|---|
| `RoundStateChanged` | RemoteEvent | S→C | Broadcast phase + round end-time |
| `RoleAssigned` | RemoteEvent | S→C (targeted) | Tell a player their own role |
| `TransformToggled` | RemoteEvent | C→S | Alien requests equip/unequip (form swap) |
| `AlienAttacked` | RemoteEvent | C→S | Alien (equipped) requests an attack; server does range + target validation |
| `FreezeFired` | RemoteEvent | C→S | Scientist/holder requests a shot (aim point for the server raycast) |
| `FreezeCooldown` | RemoteEvent | S→C (targeted) | Cooldown start/remaining for HUD indicator |
| `AbductionOccurred` | RemoteEvent | S→C | Notify abduction (for VFX/spectator enrollment) |
| `RoundResult` | RemoteEvent | S→C | Winner/draw announcement |
| `SpectatorTargets` | RemoteFunction | C→S | Fetch current alive-player list for camera cycling |

Clients send **intent only**; all effects are server-validated. No client is ever told another player's role.

---

## 13. Out of Scope (not in the rules — do not build unless requested)

- Multiple aliens/scientists, role skins/variants, persistence/leaderboards, matchmaking across places, in-round chat restrictions beyond spectator muting, anti-cheat beyond server authority, and cosmetic shops.

---

## 14. Resolved Design Decisions

Previously open questions, now confirmed:

1. **Abduction trigger** — explicit **attack input**, and the target must be **within range** (`ABDUCT_RANGE`, server-validated). Not passive touch. (section 6)
2. **Freeze hit model** — **raycast**, server-resolved. (section 7)
3. **Dropped gun + Alien** — the **Alien cannot pick up** the gun; only surviving Humans can. (section 7)
4. **Alien leaves mid-round** — round **ends immediately**, everyone teleported to the lobby (no winner), then normal intermission. (section 10)
5. **Role repeat** — **allowed**; a player may hold the same role in consecutive rounds. (section 5)
6. **`ABDUCT_RANGE`** — **5 studs** (section 11).
