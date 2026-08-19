fx_version 'cerulean'
game 'gta5'

name 'fivewatch'
description 'FiveWatch connect-check client — checks connecting players against the network, with configurable reject/quarantine/alert/log actions per report category'
version '0.2.0'
url 'https://fivewatch.net'
license 'MIT'

shared_scripts {
  'config.lua'
}

client_scripts {
  'client.lua'
}

server_scripts {
  'server.lua'
}
