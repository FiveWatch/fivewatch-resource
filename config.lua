FiveWatch = FiveWatch or {}

FiveWatch.Config = {
  -- Base URL of the FiveWatch API, no trailing slash.
  apiUrl = 'https://api.fivewatch.net',

  -- Per-server API key — get one at https://app.fivewatch.net/servers.
  apiKey = 'CHANGE-ME',

  -- If the API can't be reached (timeout, network error), allow the player
  -- to join rather than blocking connections on a FiveWatch outage. Mirrors
  -- the API's own FAIL_OPEN default — see project plan section 4.1.
  failOpen = true,

  -- Milliseconds to wait for a response before treating it as unreachable.
  requestTimeoutMs = 3000,

  -- Milliseconds to reuse the last connect-check result for the same
  -- identifier instead of firing a new request — a player scripting rapid
  -- connect/disconnect cycles would otherwise fire one outbound request per
  -- attempt, unbounded, fast enough to burn through this server's shared
  -- FiveWatch rate limit and deny real players' checks during the burst.
  checkDebounceMs = 5000,

  -- What happens on a `flagged` result, per report category — checked
  -- against every *approved* report on the connecting player, worst wins
  -- (reject > quarantine > alert > log) if they've got more than one.
  --   'reject'     — deferrals.done() with a reason; the join never completes.
  --   'quarantine' — the join completes, but the player is marked (a state
  --                  bag, see README "Building on quarantine") and, if
  --                  quarantine.teleportCoords is set, moved there. What
  --                  "quarantined" actually restricts is up to your own
  --                  scripts — FiveWatch marks the player, it doesn't know
  --                  your framework's permission system.
  --   'alert'      — the join completes; online staff (ace permission
  --                  below) get notified.
  --   'log'        — the join completes; server console only.
  levels = {
    cheating = 'reject',
    exploiting = 'reject',
    chargeback_fraud = 'quarantine',
    other = 'alert',
  },

  -- `disputed` results are inherently contested (an appeal is in progress
  -- or already ruled on) — one action for all of them rather than
  -- per-category, since "how sure are we" matters more here than category.
  disputedAction = 'alert',

  quarantine = {
    -- Optional vec3, e.g. `vector3(0.0, 0.0, 100.0)`. Leave nil to skip the
    -- teleport and just set the state bag.
    teleportCoords = nil,
  },

  -- Ace permission checked to decide who gets an in-game alert (`alert` and
  -- `quarantine` actions). Grant it in server.cfg, e.g.:
  --   add_ace group.admin fivewatch.staff allow
  --   add_principal identifier.license:xxxx group.admin
  staffAce = 'fivewatch.staff',

  -- oxmysql (github.com/overextended/oxmysql) is optional — if the resource
  -- is running, FiveWatch logs every non-clear connect-check to a local
  -- `fivewatch_events` table for the server's own audit trail, independent
  -- of the FiveWatch dashboard. Auto-detected; set false to opt out even if
  -- oxmysql is present.
  useOxMysql = true,
}
