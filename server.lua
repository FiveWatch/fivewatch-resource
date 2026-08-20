-- Optional integrations, detected at runtime rather than declared as hard
-- fxmanifest dependencies — this resource has to work on a server that has
-- neither installed. Calling exports.<resource>:x() on a resource that
-- isn't running errors, so every use of these is guarded by the flag.
local hasOxLib = GetResourceState('ox_lib') == 'started'
local hasOxMysql = GetResourceState('oxmysql') == 'started' and FiveWatch.Config.useOxMysql

local function debugPrint(msg)
  if hasOxLib then
    lib.print.info(('[fivewatch] %s'):format(msg))
  else
    print(('[fivewatch] %s'):format(msg))
  end
end

-- nil on anything that isn't a decodable JSON object, so callers can just
-- check truthiness instead of juggling pcall's ok/err pair themselves.
local function decodeBody(responseText)
  local ok, body = pcall(json.decode, responseText)
  if ok and type(body) == 'table' then return body end
  return nil
end

CreateThread(function()
  if not hasOxMysql then return end
  exports.oxmysql:execute([[
    CREATE TABLE IF NOT EXISTS fivewatch_events (
      id INT AUTO_INCREMENT PRIMARY KEY,
      license2 VARCHAR(64) NOT NULL,
      player_name VARCHAR(128),
      status VARCHAR(16) NOT NULL,
      category VARCHAR(32),
      action_taken VARCHAR(16) NOT NULL,
      created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
    )
  ]])
end)

local function logEvent(license2, playerName, status, category, action)
  if not hasOxMysql then return end
  exports.oxmysql:execute(
    'INSERT INTO fivewatch_events (license2, player_name, status, category, action_taken) VALUES (?, ?, ?, ?, ?)',
    { license2, playerName, status, category, action }
  )
end

-- Grant the ace in server.cfg: add_ace group.admin fivewatch.staff allow
local function notifyStaff(message)
  for _, playerId in ipairs(GetPlayers()) do
    if IsPlayerAceAllowed(playerId, FiveWatch.Config.staffAce) then
      TriggerClientEvent('chat:addMessage', tonumber(playerId), { args = { '^1[FiveWatch]', message } })
    end
  end
end

local ACTION_SEVERITY = { reject = 4, quarantine = 3, alert = 2, log = 1 }

-- Picks the worst-case action across every *approved* report on the
-- player — one report is enough to trigger the category it's filed under,
-- and a player with several takes whichever configured action is strictest.
local function resolveAction(body)
  if body.status == 'disputed' then
    return FiveWatch.Config.disputedAction, nil
  end

  local worst, worstCategory = 'log', nil
  for _, report in ipairs(body.reports or {}) do
    if report.status == 'approved' then
      local action = FiveWatch.Config.levels[report.category] or 'log'
      if (ACTION_SEVERITY[action] or 0) > (ACTION_SEVERITY[worst] or 0) then
        worst, worstCategory = action, report.category
      end
    end
  end
  return worst, worstCategory
end

-- Filled in by the `quarantine` branch below, consumed once the client
-- confirms it's actually spawned (see "Building on quarantine" in the
-- README for why this can't just happen inline in playerConnecting).
local pendingQuarantine = {}

-- Debounces repeated connect-check requests for the same identifier —
-- without this, a player scripting rapid connect/disconnect cycles fires
-- one outbound HTTP request per attempt with no limit, which can burn
-- through this server's shared FiveWatch rate limit fast enough to deny
-- real players' checks during the burst. Reuses the actual last response,
-- not a blanket fail-open, so a just-rejected player can't bypass the
-- reject by reconnecting inside the window.
--
-- Known limitation: the cache is only populated once a response actually
-- lands, not when the request is first fired, so reconnect attempts faster
-- than the round trip to the FiveWatch API (rare, but possible) still each
-- fire their own request rather than being deduped. Closing that fully
-- would mean queuing later connections to await the in-flight request's
-- result instead of just letting them through — a bigger change than this
-- debounce is worth for how narrow that window actually is in practice.
local recentChecks = {}

-- os.time() (whole seconds since epoch), not GetGameTimer() — GetGameTimer
-- is a 32-bit millisecond counter that wraps roughly every 24.8 days, and
-- resource restarts are common enough on updates/maintenance that a server
-- can genuinely stay up past that. A wrapped timer makes `now - entry.ts`
-- go negative, which silently defeats both the prune (`> debounceMs` never
-- fires) and the freshness check (`< debounceMs` stays true) — every
-- previously-cached license2 would then serve an arbitrarily stale result
-- (e.g. a since-banned player let in on an old "clear") for the next cycle.
-- Second granularity is fine here; the debounce window is a few seconds.

local function cachedCheckResult(license2)
  local now = os.time()
  local debounceSec = math.ceil(FiveWatch.Config.checkDebounceMs / 1000)
  -- Opportunistic prune on every lookup — keeps this bounded by recent
  -- connection activity rather than every license2 ever seen, with no
  -- separate cleanup thread needed.
  for id, entry in pairs(recentChecks) do
    if now - entry.ts > debounceSec then recentChecks[id] = nil end
  end
  local entry = recentChecks[license2]
  if entry and now - entry.ts < debounceSec then return entry end
  return nil
end

local function cacheCheckResult(license2, statusCode, responseText)
  recentChecks[license2] = { statusCode = statusCode, responseText = responseText, ts = os.time() }
end

-- Printed once, not per-connection — a free-tier key gets a 403 on every
-- single check, and with failOpen (the default) that's otherwise silent:
-- every player gets waved through with no indication connect-checks are
-- doing nothing at all, unless an operator happens to have debug on.
local warnedPaidRequired = false

-- fromCache: true when this call is replaying a debounced result rather
-- than a fresh network response (see cachedCheckResult). Per-connection
-- effects (deferrals, pendingQuarantine) still have to run every time —
-- *this* connection needs its own resolution regardless of where the
-- result came from — but logEvent/notifyStaff are about the underlying
-- check itself, not this specific connection attempt, and firing them
-- again for every debounced reconnect would just be a relocated version of
-- the same spam the debounce cache exists to prevent (one DB row / chat
-- ping per actual check, not per connection attempt).
local function handleCheckResult(deferrals, src, playerName, license2, resolvedFlag, timedOutFlag, statusCode, responseText, fromCache)
  if resolvedFlag.value or timedOutFlag.value then return end
  resolvedFlag.value = true

  if statusCode ~= 200 then
    if statusCode == 403 then
      -- Checked via the response body's machine-readable `code`, not the
      -- bare status code or the human-readable `error` text — a future
      -- unrelated 403 (bad key, WAF, etc.) shouldn't be misreported as a
      -- billing problem, and rewording the API's error message can't
      -- silently break this.
      local body = decodeBody(responseText)
      if body and body.code == 'paid_tier_required' then
        if not warnedPaidRequired then
          warnedPaidRequired = true
          print('[fivewatch] Connect-checks are disabled: this API key needs a paid FiveWatch account. Players are joining unchecked. See fivewatch.net/servers.')
        end
        -- Always fail open here, regardless of the failOpen setting — this
        -- is a billing gap on this server, not a service outage, and
        -- shouldn't be able to lock every connecting player out.
        deferrals.done()
        return
      end
    end
    debugPrint(('check failed with status %s'):format(tostring(statusCode)))
    if FiveWatch.Config.failOpen then deferrals.done() else deferrals.done('FiveWatch check unavailable, try again shortly.') end
    return
  end

  local body = decodeBody(responseText)
  if not body or not body.status then
    debugPrint('check returned an unreadable response')
    if FiveWatch.Config.failOpen then deferrals.done() else deferrals.done('FiveWatch check unavailable, try again shortly.') end
    return
  end

  if body.status == 'clear' then
    deferrals.done()
    return
  end

  local action, category = resolveAction(body)
  if not fromCache then logEvent(license2, playerName, body.status, category, action) end
  TriggerEvent('fivewatch:playerFlagged', src, body.status, category, action)

  if action == 'reject' then
    deferrals.done(('You have an active FiveWatch report (%s). Visit fivewatch.net to appeal.'):format(body.status))
    return
  end

  deferrals.done()

  if action == 'quarantine' then
    pendingQuarantine[src] = { status = body.status, category = category }
  elseif action == 'alert' then
    if not fromCache then
      notifyStaff(('%s connecting with status: %s (%s)'):format(playerName, body.status, category or 'contested'))
    end
  else
    debugPrint(('%s connecting with status: %s'):format(playerName, body.status))
  end
end

AddEventHandler('playerConnecting', function(name, setKickReason, deferrals)
  local src = source
  deferrals.defer()
  Citizen.Wait(0)
  deferrals.update('Checking FiveWatch history...')

  local license2 = GetPlayerIdentifierByType(src, 'license2')
  if not license2 then
    debugPrint(('no license2 for connecting player %s, allowing join'):format(name))
    deferrals.done()
    return
  end

  local cached = cachedCheckResult(license2)
  if cached then
    handleCheckResult(deferrals, src, name, license2, { value = false }, { value = false }, cached.statusCode, cached.responseText, true)
    return
  end

  local resolvedFlag = { value = false }
  local timedOutFlag = { value = false }

  SetTimeout(FiveWatch.Config.requestTimeoutMs, function()
    if resolvedFlag.value then return end
    timedOutFlag.value = true
    debugPrint(('check timed out for %s'):format(name))
    if FiveWatch.Config.failOpen then
      deferrals.done()
    else
      deferrals.done('FiveWatch check timed out, try again shortly.')
    end
  end)

  PerformHttpRequest(
    FiveWatch.Config.apiUrl .. '/v1/check',
    function(statusCode, responseText)
      -- Only a genuine 200 verdict (clear or flagged) is worth reusing for
      -- a reconnecting player. Caching a non-200 response (a transient 5xx,
      -- a curl/DNS error reported as statusCode 0, a paid-tier 403) would
      -- replay that failure for the rest of the debounce window instead of
      -- giving the next reconnect attempt a fresh shot at the network —
      -- with failOpen=true that's a flagged player getting waved through
      -- purely because the last check happened to error, and with
      -- failOpen=false it's a legitimate player stuck getting rejected
      -- after the API has already recovered.
      if statusCode == 200 then
        cacheCheckResult(license2, statusCode, responseText)
      end
      handleCheckResult(deferrals, src, name, license2, resolvedFlag, timedOutFlag, statusCode, responseText)
    end,
    'POST',
    json.encode({ license2 = license2 }),
    {
      ['Content-Type'] = 'application/json',
      ['x-api-key'] = FiveWatch.Config.apiKey,
    }
  )
end)

-- FXServer reuses small integer player ids once a slot frees up, and
-- there's a real window for that: a player can be marked pending here, then
-- disconnect (crash, alt-F4, connection drop) before their client ever
-- fires playerSpawned. Without this, the *next* player who lands on that
-- same id would silently inherit someone else's quarantine the moment
-- their own client.lua fires fivewatch:clientReady — wrong player, no
-- check of their own involved at all.
AddEventHandler('playerDropped', function()
  pendingQuarantine[source] = nil
end)

-- Quarantine can't be applied inline in playerConnecting: the player's ped
-- doesn't exist yet at that point (deferrals only gate the connection
-- handshake, not the world-load that follows), so a teleport there would
-- silently no-op. client.lua fires this once the client's own native
-- `playerSpawned` event confirms the ped is real.
RegisterNetEvent('fivewatch:clientReady', function()
  local src = source
  local pending = pendingQuarantine[src]
  if not pending then return end
  pendingQuarantine[src] = nil

  local Player = Player(src)
  if Player then
    Player.state:set('fivewatch:quarantined', pending, true)
  end

  local coords = FiveWatch.Config.quarantine.teleportCoords
  if coords then
    SetEntityCoords(GetPlayerPed(src), coords.x, coords.y, coords.z, false, false, false, true)
  end

  notifyStaff(('quarantined on join: %s (%s)'):format(GetPlayerName(src) or ('player %s'):format(src), pending.category or pending.status))
end)

-- Lets a connected player prove ownership of their license2 to FiveWatch for
-- an appeal: this server reads it live and vouches for them, no separate
-- FiveWatch-run verification server needed. Assumes the default `chat`
-- resource for chat:addMessage; adjust if this server uses a different one.
local function notifyPlayer(src, message)
  TriggerClientEvent('chat:addMessage', src, { args = { '^3[FiveWatch]', message } })
end

RegisterCommand('fivewatch-verify', function(src)
  if src == 0 then return end

  local license2 = GetPlayerIdentifierByType(src, 'license2')
  if not license2 then
    notifyPlayer(src, 'Could not read your license identifier, try again shortly.')
    return
  end

  PerformHttpRequest(
    FiveWatch.Config.apiUrl .. '/v1/verify-tokens',
    function(statusCode, responseText)
      if statusCode ~= 201 then
        notifyPlayer(src, 'Verification failed, try again shortly.')
        return
      end
      local body = decodeBody(responseText)
      if not body or not body.code then
        notifyPlayer(src, 'Verification failed, try again shortly.')
        return
      end
      notifyPlayer(src, ('Your appeal code: %s (valid %s min). Enter it at fivewatch.net/appeal.'):format(
        body.code, tostring(body.expiresInMinutes)
      ))
    end,
    'POST',
    json.encode({ license2 = license2 }),
    {
      ['Content-Type'] = 'application/json',
      ['x-api-key'] = FiveWatch.Config.apiKey,
    }
  )
end, false)
