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

local function handleCheckResult(deferrals, src, playerName, license2, resolvedFlag, timedOutFlag, statusCode, responseText)
  if resolvedFlag.value or timedOutFlag.value then return end
  resolvedFlag.value = true

  if statusCode ~= 200 then
    debugPrint(('check failed with status %s'):format(tostring(statusCode)))
    if FiveWatch.Config.failOpen then deferrals.done() else deferrals.done('FiveWatch check unavailable, try again shortly.') end
    return
  end

  local ok, body = pcall(json.decode, responseText)
  if not ok or not body or not body.status then
    debugPrint('check returned an unreadable response')
    if FiveWatch.Config.failOpen then deferrals.done() else deferrals.done('FiveWatch check unavailable, try again shortly.') end
    return
  end

  if body.status == 'clear' then
    deferrals.done()
    return
  end

  local action, category = resolveAction(body)
  logEvent(license2, playerName, body.status, category, action)
  TriggerEvent('fivewatch:playerFlagged', src, body.status, category, action)

  if action == 'reject' then
    deferrals.done(('You have an active FiveWatch report (%s). Visit fivewatch.net to appeal.'):format(body.status))
    return
  end

  deferrals.done()

  if action == 'quarantine' then
    pendingQuarantine[src] = { status = body.status, category = category }
  elseif action == 'alert' then
    notifyStaff(('%s connecting with status: %s (%s)'):format(playerName, body.status, category or 'contested'))
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
      local ok, body = pcall(json.decode, responseText)
      if not ok or not body or not body.code then
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
