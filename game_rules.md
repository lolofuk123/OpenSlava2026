# Game Rules — Alien Abduction

A round-based social-deduction game for a single Roblox place. Every round, one
player secretly becomes the **Alien** and one becomes the **Scientist**. The
Alien wins by abducting everyone; the Scientist (and the surviving humans)
win by finding and freezing the Alien first.

## Roles

| Role | Count per round | Appearance | Tool |
|---|---|---|---|
| Alien | 1 | Normal avatar until it transforms | Transform |
| Scientist | 1 | Normal avatar | Freeze Gun |
| Human | everyone else | Normal avatar | None |

All three roles look like ordinary player avatars at round start — there is
no visual tell for who is the Alien or the Scientist.

## Round Flow

1. **Lobby** — players free-roam in the lobby between rounds.
2. **Role assignment** — when a round starts, the server randomly picks one
   player as Alien and one different player as Scientist; everyone else is
   Human.
3. **Teleport in** — all players are teleported from the lobby into the map.
4. **Round start** — Alien, Scientist, and Humans can now act (see below).
5. **Round end** — triggered by any win condition or by the round timer
   expiring (see [Win Conditions](#win-conditions)). All players are
   teleported back to the lobby.
6. **Intermission** — after 10 seconds in the lobby, step 2 runs again for
   the next round.

## Alien

- Has a **Transform** tool, used the same way a normal tool is equipped/
  unequipped (toggle).
- **Unequipped:** looks like a normal avatar, indistinguishable from a Human.
- **Equipped:** character switches to the Alien model — a single fixed
  appearance with green body parts (no selectable skins/color variants).
  While in this form, touching/attacking another player **abducts** them.
- Toggling back to the normal avatar at any time is allowed (no cooldown) —
  this is how the Alien blends back in after attacking.
- Abducted players immediately leave play and enter **Spectator Mode**.

## Scientist

- Has a **Freeze Gun** tool, equipped/unequipped the same way as a normal
  tool.
- Infinite ammo, with a 2.5 second cooldown between shots. While on
  cooldown, the Scientist gets an on-screen indicator showing the gun can't
  fire yet (e.g. a cooldown bar/timer on the HUD).
- Shooting a player with the Freeze Gun freezes them:
  - **Hits the Alien:** Alien is frozen → round ends, Scientist + all
    surviving Humans win.
  - **Hits anyone else (a Human):** both the Scientist **and** the
    wrongly-frozen Human are eliminated from the round and enter Spectator
    Mode. The round continues — the Alien still needs to abduct the rest.
- If the Scientist is eliminated (by abduction **or** by a wrong freeze),
  the Freeze Gun drops at their last position. Any surviving Human can pick
  it up and continue trying to identify and freeze the Alien.
  - The Alien cannot use the Freeze Gun.

## Spectator Mode

- Entered automatically the moment a player is abducted or eliminated.
- Spectators can cycle between currently-alive players' views (e.g.
  next/previous), but cannot move, interact, or communicate with the live
  round.

## Win Conditions

- **Alien wins:** every other player (all Humans and the Scientist, or
  whoever is left after wrong-freeze eliminations) has been abducted.
- **Scientist + Humans win:** the Scientist successfully freezes the Alien.
- **Draw / timeout:** a 5-minute round timer runs in the background. If it
  expires before either side wins, the round ends with no winner and play
  returns to the lobby as usual.

Either way, round end always teleports everyone back to the lobby, followed
by the 10-second intermission before the next round.

## Confirmed Parameters

- Freeze Gun cooldown: 2.5 seconds, with an on-cooldown indicator on the HUD.
- Round timer: 5 minutes.
- Minimum players to start a round: 3 (Alien + Scientist + at least 1 Human).
  If fewer than 3 players are in the lobby, the next round does not start
  until the minimum is met.
- A player who joins mid-round enters Spectator Mode immediately and joins
  the next round's role assignment once it starts.
