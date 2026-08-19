-- `playerSpawned` is the game engine's own event, fired once the local
-- player's ped actually exists — playerConnecting/deferrals on the server
-- side only gate the connection handshake, well before that point, so
-- anything that needs a real ped (the quarantine teleport) has to wait for
-- this round-trip rather than running inline in the connect hook.
AddEventHandler('playerSpawned', function()
  TriggerServerEvent('fivewatch:clientReady')
end)
