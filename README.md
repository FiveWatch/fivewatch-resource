# fivewatch (FiveM resource)

Open source (MIT) FiveM resource for [FiveWatch](https://fivewatch.net) — checks
connecting players against the network's report history and applies a
configurable action per report category: reject the join outright, quarantine
them, alert your staff, or just log it. No hard dependencies; optionally
integrates with [ox_lib](https://overextended.dev/docs/ox_lib) and
[oxmysql](https://overextended.dev/docs/oxmysql) if you already run them.

Part of [FiveWatch](https://fivewatch.net), a cross-server player history /
ban-share network for FiveM — this is the client resource; the network side
(dashboard, API) lives in a separate private repo. Full endpoint reference and
setup docs: [app.fivewatch.net/docs](https://app.fivewatch.net/docs).

## Install

1. Clone (or download the zip of) this repo into your server's `resources/`
   directory as `fivewatch`.
2. Get an API key at [app.fivewatch.net/servers](https://app.fivewatch.net/servers) (Discord sign-in, then a server-ownership verification step — see the docs link above).
3. Edit `config.lua`: set `apiUrl` and `apiKey`.
4. Add `ensure fivewatch` to your `server.cfg`.

`config.failOpen = true` (default) lets players join if the FiveWatch API is
unreachable or times out, rather than blocking connections on a FiveWatch-side
outage.

## What happens on a flagged/disputed result

Every connecting player's `license2` gets checked against `POST /v1/check`.
On `clear`, nothing happens — the join proceeds normally. On `flagged` or
`disputed`, `config.lua`'s `levels` table (keyed by report category) and
`disputedAction` decide what happens:

| Action | Effect |
|---|---|
| `reject` | The join never completes — `deferrals.done(reason)`. |
| `quarantine` | The join completes, but the player is marked (see below) and optionally teleported to `quarantine.teleportCoords`. |
| `alert` | The join completes; online staff (holding the `staffAce` ace permission) get an in-game chat alert. |
| `log` | The join completes; server console only. |

If a player has more than one approved report, the *worst* configured action
across their categories wins (`reject` > `quarantine` > `alert` > `log`).
`disputed` results use one setting for all of them (`disputedAction`) rather
than per-category, since "how sure are we" matters more there than category —
an appeal is either in progress or already ruled on.

Grant the staff ace in `server.cfg`:

```
add_ace group.admin fivewatch.staff allow
add_principal identifier.license:xxxxxxxx group.admin
```

## Building on quarantine

FiveWatch marks a quarantined player, it doesn't know your framework's
permission system or UI — enforcing actual restrictions (no weapons, locked
inventory, a holding-cell script, whatever your server does for this) is left
to your own scripts, reacting to either of:

- **State bag** — `Player(source).state['fivewatch:quarantined']` is set to
  `{ status, category }` (or `nil` if not quarantined). Replicated to the
  client, so client scripts can read it too via
  `LocalPlayer.state['fivewatch:quarantined']`.
- **Server event** — `AddEventHandler('fivewatch:playerFlagged', function(src, status, category, action) ... end)`
  fires for every non-`clear` result (not just quarantine), immediately on
  connect rather than waiting for the player to fully spawn.

The quarantine teleport (if `quarantine.teleportCoords` is set) only happens
once the client's own `playerSpawned` event confirms the player's ped
actually exists — `playerConnecting`/`deferrals` only gate the connection
handshake, well before that point, so a teleport attempted inline there would
silently no-op. `client.lua` handles that round-trip; you don't need to do
anything for the built-in teleport to work.

## Optional integrations

Both are detected at runtime (`GetResourceState`) — install order doesn't
matter, and neither is a hard dependency in `fxmanifest.lua`, so this resource
works fine without either.

- **oxmysql** — if running, every non-`clear` result gets logged to a local
  `fivewatch_events` table (license2, player name, status, category, action
  taken, timestamp), created automatically on first start. This is a local
  audit trail independent of the FiveWatch dashboard's own audit log — useful
  if you want to query your own server's history directly. Set
  `config.useOxMysql = false` to opt out even if oxmysql is present.
- **ox_lib** — used for nicer console output (`lib.print.info` instead of a
  plain `print`) when present. Purely a debug-output nicety; nothing
  functional depends on it.

## Appeal verification

Any server running this resource can vouch for a connected player's identity
for an appeal — no separate FiveWatch-run verification server needed. A
player runs `/fivewatch-verify` in chat; the resource reads their live
license2 server-side and requests a short-lived code from the API, sent back
via chat (assumes the default `chat` resource for `chat:addMessage` — adjust
`notifyPlayer` in `server.lua` if this server uses a different one). They
enter that code plus the report ID on the appeal portal.

## Config reference

See the comments in `config.lua` — every option is documented inline there,
not duplicated here to avoid the two drifting apart.
