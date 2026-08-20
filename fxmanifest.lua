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
    'server/oxcore.lua',
    'server/main.lua',
}

-- The generated tune file. `data_file` makes the game load it at resource start,
-- which is what keeps edits applied from startup with no scripting involved.
--
-- It sits at the resource root rather than in a subfolder because
-- SaveResourceFile cannot create directories -- a missing folder is the usual
-- reason a write silently fails.
files {
    'handling.meta',
}

data_file 'HANDLING_FILE' 'handling.meta'

dependency 'ox_lib'

-- ox_core is optional and deliberately NOT declared as a dependency: the
-- integration is detected at runtime, so the resource starts either way. When
-- ox_core is running the editor hooks its vehicle spawns and exposes tier-aware
-- wrappers around Ox.CreateVehicle / Ox.SpawnVehicle. Start ox_core before this
-- resource so the hooks catch vehicles spawned during boot.
