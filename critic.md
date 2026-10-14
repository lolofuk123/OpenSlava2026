# critic.md — Review of specs.md

Iterative critique. Each pass lists flaws in the current `specs.md`; the spec is then upgraded to address them. The loop ends when a pass finds nothing substantive.

---

## Iteration 1

### Correctness / misconceptions

1. **Freeze & abduction target is role-based, not form-based — never stated.** The whole point of the game is that the Alien toggles back to a normal avatar to blend in. The spec never explicitly says the Freeze Gun freezes the Alien *regardless of current visual form* (disguised as a human), and that freeze/abduction resolution keys off the server-side **Role**, not appearance. This is the central mechanic and is currently only implicit. **Major.**

2. **Transform tool dual-purpose is conflated.** Section 6 says abduction is triggered by "the Alien activates the Transform tool / clicks to attack," but the same tool's equip/unequip is what toggles Alien form. The spec never cleanly separates the two input channels: *equip/unequip* (`Tool` equipped state → form swap) vs. *activate* (`Tool.Activated`/click while equipped → attack). As written it's ambiguous whether a click toggles form or attacks. **Major.**

3. **Win-team terminology breaks when the Scientist is dead.** Win condition 2 and section 1 say "Scientist + all surviving Humans win," but a Human can pick up the dropped gun and freeze the Alien after the Scientist is already eliminated. The winning side should be framed as "all surviving non-Alien players (the human team)," and it must be stated that eliminated/abducted players do **not** count as winners. **Medium.**

### Missing behavior

4. **No round-end cleanup of a dropped Freeze Gun.** If the gun is lying in the map at round end, nothing removes it. Section 4 step 6 only "strips tools" from players. Dropped-gun/world-object cleanup must be explicit or a stale gun persists into the next round. **Medium.**

5. **Missing-shot / cooldown interaction unspecified.** If the Scientist fires and the raycast hits no player (or a wall), does the 2.5s cooldown still apply? Without this, a player could "scan" freely with zero-cost misses. Needs a decision (cooldown applies on every fire). **Medium.**

6. **Freeze Gun range unspecified.** "Infinite ammo" is stated but not range. Is it unlimited line-of-sight, or capped at some stud distance for the raycast? Undefined. **Medium.**

7. **Self-targeting not excluded.** Nothing says the Scientist cannot target themselves (a self wrong-freeze is nonsensical) or that the Alien's attack excludes self. **Low.**

8. **Round continues below MIN_PLAYERS not stated.** Rules say 3 players are required to *start*. The spec never states that an in-progress round keeps running if the count drops below 3 (resolving only via win conditions), which is the correct reading. Currently a reader could assume the round aborts. **Low.**

9. **ABDUCT_RANGE measurement reference undefined.** "Within range of the Alien" — measured between which points? Should specify HumanoidRootPart-to-HumanoidRootPart distance. **Low.**

### Consistency / documentation

10. **Stale `[Assumption]` convention.** The intro (line 5) still says the spec "flags it as an `[Assumption]` so it can be confirmed," but every assumption has been resolved and no `[Assumption]` tags remain. The sentence is now misleading. **Low.**

11. **Wrong section cross-reference.** Line 24 comment says `GameConfig.luau -- all tunable constants (section 9)`, but the constants table is **section 11**. **Low.**

12. **Section 1 omits the attack intent.** The overview lists client intents as "equip/toggle, fire" but there is also the Alien attack intent (`AlienAttacked`). **Low.**

### Robustness

13. **Simultaneous win-event atomicity not addressed.** Two win-triggering events in the same frame (e.g., Alien abducts the last Human the same moment it is frozen) need a defined resolution order. Luau on the server is single-threaded, so the first-processed event should win and further win-checks are skipped once the round is `Ending`; this guarantee should be written down. **Low.**

*All 13 addressed in spec. Proceeding to iteration 2.*

---

## Iteration 2

### Correctness

1. **Win condition 1 breaks on disconnect.** It reads "every non-Alien participant is `Spectator`." A Human who *disconnects* (rather than being abducted) is neither `Alive` nor `Spectator` — they are gone. The condition should be stated as "**no `Alive` non-Alien players remain**," which handles abduction, elimination, *and* disconnect uniformly. **Medium.**

2. **Default Roblox Tool pickup contradicts the Alien-can't-pickup rule.** A `Tool` parented into the workspace auto-equips to any `Humanoid` that touches it. So by default the Alien *would* pick up a dropped Freeze Gun on contact. The spec asserts "the server blocks pickup by the Alien" but doesn't say how this is possible given default behavior — it needs an explicit mechanism (e.g. gun is not a free-floating `Tool` but a custom pickup prompt/part the server grants only to eligible Humans, or the server immediately re-drops it if a non-eligible character acquires it). **Medium.**

### Missing behavior

3. **Alien form restore needs a cached original appearance.** Section 6 says unequipping "swaps back to the normal avatar," but the spec never says the server must **capture the player's original appearance/HumanoidDescription at round start** and restore it on untransform. Without this, the restore is undefined. **Medium.**

4. **Character death / environment hazards during a round unhandled.** There is no combat damage, but a player can still die (fall off the map, drown, etc.). The spec doesn't say whether default respawn is on, or what happens to a player who dies mid-round without being abducted or frozen. Default `CharacterAutoLoads` would respawn them in an undefined state. Needs a decision: disable auto-respawn and have the server own all spawning; define that a mid-round environmental death is treated as elimination → Spectator (or make the map hazard-free). **Medium.**

5. **Participant roster for win checks is undefined.** Win checks reference "participants," but the set is never pinned down. It should be: the roster is fixed at round start (step 2); mid-round joiners are excluded; a participant who disconnects is removed from both `Alive` and the roster. **Low.**

*All 5 addressed in spec. Proceeding to iteration 3.*

---

## Iteration 3

### Design clarity

1. **Equipping the Freeze Gun is itself a visible tell — not noted.** The rules say there's no visual tell *at round start*, and tools work like normal tools. A consequence: when the Scientist **equips** the Freeze Gun it becomes visible in-hand, revealing them — exactly mirroring how the Alien reveals itself by transforming. An implementer could wrongly try to hide the gun. The spec should state this symmetry so the gun is intentionally visible when equipped. **Low.**

### Implementation ordering

2. **Tool-granting vs. character load ordering.** With `CharacterAutoLoads` disabled (section 9), tools can only be granted *after* the server loads each character at the map spawn. Step 3 currently lists teleport and tool-grant together without ordering; it should say characters load at map spawns first, then tools are granted. **Low.**

3. **Client countdown needs synced server time.** Section 4 says clients "receive the end-time to render a countdown," but not how to avoid clock skew. Should specify the server sends an absolute timestamp from `workspace:GetServerTimeNow()` and the client renders remaining = endTime − `GetServerTimeNow()`. **Low.**

### Cosmetic

4. **Section 14 list numbering gap.** Items 1–5 are grouped, then item 6 sits after a blank line as if orphaned. Should be a single clean list. **Trivial.**

*All 4 addressed in spec. Proceeding to iteration 4.*

---

## Iteration 4

Full re-read of `specs.md` against `game_rules.md`. Checked: role/form logic, round lifecycle, all three roles' mechanics, spectator rules, win conditions (incl. disconnect, timeout, alien-leave, below-min), config constants, remotes table, and client/server/shared boundaries.

**No substantive flaws found.** Every rule in `game_rules.md` maps to a spec section; every previously-flagged correctness, missing-behavior, robustness, clarity, and ordering issue has been resolved; all designer decisions are recorded and internally consistent. One trivial doc-label mismatch (the `InputController` comment) was corrected inline.

**Loop terminated — the critic is clean.**

