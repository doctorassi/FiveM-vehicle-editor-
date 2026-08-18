fx_version 'cerulean'
game 'gta5'
lua54 'yes'

name 'fivem-vehicle-editor'
author 'doctorassi'
description 'ox_lib powered handling + performance editor with tiers 1-5, persisted to a real handling.meta'
version '1.0.0'

shared_scripts {
    '@ox_lib/init.lua',
    'config.lua',
    'shared/fields.lua',
    'shared/util.lua',
}

client_scripts {
    'client/originals.lua',
    'client/apply.lua',
    'client/menu.lua',
}

server_scripts {
    'server/store.lua',
    'server/meta.lua',
    'server/main.lua',
}

-- The generated tune file. `data_file` makes the game load it at resource start,
-- which is what keeps edits applied from startup with no scripting involved.
files {
    'data/handling.meta',
}

data_file 'HANDLING_FILE' 'data/handling.meta'

dependency 'ox_lib'
