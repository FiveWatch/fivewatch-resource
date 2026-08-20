fx_version 'cerulean'
game 'gta5'

name 'fivewatch'
description 'FiveWatch connect-check client — checks connecting players against the network, with configurable reject/quarantine/alert/log actions per report category'
version '0.2.0'
url 'https://fivewatch.net'
license 'MIT'

client_scripts {
  'client.lua'
}

-- config.lua holds FiveWatch.Config.apiKey — server-only. It was previously
-- under shared_scripts, which FXServer sends to every connecting client;
-- client.lua never reads any config value, so there was no reason for it to
-- load client-side at all. Listed before server.lua since server.lua
-- references the FiveWatch.Config global at load time.
server_scripts {
  'config.lua',
  'server.lua'
}
