--[[
    Server entry point: startup load, ox_lib callbacks, autosave, sync.
]]

local saveScheduled = false

--------------------------------------------------------------------------------
-- Load check
--------------------------------------------------------------------------------
-- A server script that fails to load, or never reaches the deployment at all,
-- is not an error in FiveM: the globals it defines are simply nil, and the
-- first caller dies somewhere unrelated with "attempt to index a nil value".
-- Checking up front turns that into one actionable line naming the file.

local REQUIRED = {
    { global = 'Store',  file = 'server/store.lua',  fns = { 'CanEdit', 'BuildSync', 'ResolveValues' } },
    { global = 'Meta',   file = 'server/meta.lua',   fns = { 'Save', 'Load', 'Build', 'Diagnose' } },
    { global = 'State',  file = 'server/meta.lua',   fns = { 'Save', 'Load' } },
    { global = 'OxCore', file = 'server/oxcore.lua', fns = { 'Init', 'BuildPolicy' } },
    { global = 'Fields', file = 'shared/fields.lua', fns = {} },
    { global = 'Util',   file = 'shared/util.lua',   fns = { 'SanitizeValue', 'RollTier' } },
    { global = 'Config', file = 'config.lua',        fns = {} },
}

---@return boolean ok
local function checkLoaded()
    local problems = {}

    for i = 1, #REQUIRED do
        local entry = REQUIRED[i]
        local value = _G[entry.global]

        if type(value) ~= 'table' then
            problems[#problems + 1] = ('%s is missing — %s did not load')
                :format(entry.global, entry.file)
        else
            for j = 1, #entry.fns do
                if type(value[entry.fns[j]]) ~= 'function' then
                    problems[#problems + 1] = ('%s.%s is missing — %s loaded only partially')
                        :format(entry.global, entry.fns[j], entry.file)
                end
            end
        end
    end

    if #problems == 0 then return true end

    print('[vehicle-editor] NOT STARTING — the resource did not load completely:')
    for i = 1, #problems do print('  - ' .. problems[i]) end
    print('  Check the console above for an earlier Lua error, and make sure every')
    print('  file listed in fxmanifest.lua is actually present on the server.')

    return false
end

---Set once checkLoaded passes; every entry point bails out quietly otherwise
---rather than throwing on a nil global.
local ready = false

---Coalesce rapid edits into a single file write. Every mutation calls this, so
---an edit is on disk within a second of being made -- there is no "unsaved"
---state to lose.
local function scheduleSave()
    if not ready or saveScheduled then return end

    saveScheduled = true
    SetTimeout(1000, function()
        saveScheduled = false

        -- tunes.json is the source of truth and must succeed.
        local ok = State.Save()

        -- handling.meta is a bonus that lets the game apply tunes natively at
        -- startup. It is declared as a data_file, so on some hosts the resource
        -- system holds it open and the write cannot land. That is reported once
        -- and then tolerated, because nothing depends on it.
        if Config.WriteMetaOnSave then Meta.Save() end

        if not ok then
            -- "Edits are always saved" is the whole point, so a failed autosave
            -- is told to everyone who can act on it rather than only the log.
            TriggerClientEvent('vehicleeditor:saveFailed', -1, State.lastError)
        end
    end)
end

local function broadcastSync()
    TriggerClientEvent('vehicleeditor:sync', -1, Store.BuildSync())
end

---Run a mutation with the ace check, then sync + autosave on success.
---@param source number
---@param fn fun():boolean, string?
---@return boolean ok, string? err
local function mutate(source, fn)
    if not Store.CanEdit(source) then
        return false, 'You do not have permission to edit vehicles.'
    end

    local ok, err = fn()
    if not ok then return false, err end

    broadcastSync()
    scheduleSave()
    return true, nil
end

--------------------------------------------------------------------------------
-- Callbacks
--------------------------------------------------------------------------------

lib.callback.register('vehicleeditor:getState', function(source)
    return {
        canEdit = Store.CanEdit(source),
        missing = Store.MissingOriginals(),
        sync = Store.BuildSync(),
    }
end)

lib.callback.register('vehicleeditor:setValue', function(source, model, field, value)
    return mutate(source, function()
        return Store.SetValue(model, field, value)
    end)
end)

lib.callback.register('vehicleeditor:clearValue', function(source, model, field)
    return mutate(source, function()
        return Store.ClearValue(model, field)
    end)
end)

lib.callback.register('vehicleeditor:setTier', function(source, model, tier)
    return mutate(source, function()
        return Store.SetTier(model, tier)
    end)
end)

lib.callback.register('vehicleeditor:setMod', function(source, model, modId, level)
    return mutate(source, function()
        return Store.SetMod(model, modId, level)
    end)
end)

lib.callback.register('vehicleeditor:clearMod', function(source, model, modId)
    return mutate(source, function()
        return Store.ClearMod(model, modId)
    end)
end)

---Roll one vehicle from its tier band -- the "per vehicle on request" path.
lib.callback.register('vehicleeditor:randomize', function(source, model, tier)
    return mutate(source, function()
        return Store.Randomize(model, tier)
    end)
end)

---Roll the whole configured fleet -- the "automatic" path.
lib.callback.register('vehicleeditor:randomizeAll', function(source)
    if not Store.CanEdit(source) then
        return false, 'You do not have permission to edit vehicles.'
    end

    local count = Store.RandomizeAll()
    broadcastSync()
    scheduleSave()

    return true, nil, count
end)

lib.callback.register('vehicleeditor:reset', function(source, model)
    return mutate(source, function()
        return Store.Reset(model)
    end)
end)

---Force an immediate write rather than waiting for the debounce.
lib.callback.register('vehicleeditor:save', function(source)
    if not Store.CanEdit(source) then
        return false, 'You do not have permission to edit vehicles.'
    end

    local ok, err = State.Save()
    if not ok then
        return false, ('Could not write %s: %s'):format(State.PATH, err or 'unknown error')
    end

    -- Best effort; a host that will not let us write handling.meta does not
    -- make the save a failure.
    Meta.Save()

    return true, nil
end)

---Throw away in-memory state and re-read the file from disk.
lib.callback.register('vehicleeditor:reload', function(source)
    if not Store.CanEdit(source) then
        return false, 'You do not have permission to edit vehicles.'
    end

    Store.tunes = {}
    local loaded = State.Load()
    if loaded == 0 then loaded = Meta.Load() end
    broadcastSync()

    return true, nil, loaded
end)

---A client reporting the vanilla values it read off a freshly spawned vehicle.
---Only ever accepted once per model (Store.SetOriginals refuses to overwrite),
---so a client cannot rewrite the originals of an already-tuned vehicle.
lib.callback.register('vehicleeditor:submitOriginals', function(source, snapshots, failures, skippedFields)
    if not Store.CanEdit(source) then
        return false, 'You do not have permission to edit vehicles.'
    end

    if type(snapshots) ~= 'table' then
        return false, 'invalid snapshot payload'
    end

    local stored, rejected = 0, {}

    for model, originals in pairs(snapshots) do
        local key = type(model) == 'string' and model:lower() or ''

        if Config.VehicleByModel[key] then
            local ok, err = Store.SetOriginals(model, originals)
            if ok then
                stored = stored + 1
            elseif err then
                rejected[#rejected + 1] = ('%s (%s)'):format(model, err)
            end
        end
    end

    -- Capture runs on a client, so without this the server console sees nothing
    -- and a total failure looks identical to everything being fine.
    if stored > 0 then
        print(('[vehicle-editor] captured vanilla values for %d vehicle(s)'):format(stored))
    end

    if type(skippedFields) == 'table' and #skippedFields > 0 then
        print(('[vehicle-editor] fields the handling natives would not read (left at game defaults): %s')
            :format(table.concat(skippedFields, ', ')))
    end

    for i = 1, #rejected do
        print('[vehicle-editor] snapshot rejected: ' .. rejected[i])
    end

    if type(failures) == 'table' and #failures > 0 then
        print(('[vehicle-editor] %d vehicle(s) could not be captured:'):format(#failures))
        for i = 1, #failures do
            print('  - ' .. tostring(failures[i]))
        end
    end

    if stored > 0 then
        broadcastSync()
        scheduleSave()
    end

    return true, nil, stored
end)

--------------------------------------------------------------------------------
-- Console / admin commands
--------------------------------------------------------------------------------

RegisterCommand('vehedit_autoall', function(source)
    if not Store.CanEdit(source) then
        return print('[vehicle-editor] denied: missing ' .. Config.AcePermission)
    end

    local missing = Store.MissingOriginals()
    if #missing > 0 then
        print(('[vehicle-editor] %d vehicle(s) still need a vanilla snapshot: %s')
            :format(#missing, table.concat(missing, ', ')))
        print('[vehicle-editor] open /' .. Config.Command .. ' in game once to capture them.')
    end

    local count = Store.RandomizeAll()
    broadcastSync()
    scheduleSave()

    print(('[vehicle-editor] rolled %d vehicle(s) from their tier bands'):format(count))
end, false)

RegisterCommand('vehedit_save', function(source)
    if not Store.CanEdit(source) then
        return print('[vehicle-editor] denied: missing ' .. Config.AcePermission)
    end
    local stateOk, stateErr = State.Save()
    local metaOk, metaErr, entries = Meta.Save()

    print(('[vehicle-editor] %s: %s'):format(State.PATH,
        stateOk and 'verified on disk' or ('FAILED — ' .. tostring(stateErr))))
    print(('[vehicle-editor] handling.meta: %s'):format(
        metaOk and ('verified on disk, %d entr%s'):format(entries or 0, (entries or 0) == 1 and 'y' or 'ies')
            or ('FAILED — ' .. tostring(metaErr))))
end, false)

RegisterCommand('vehedit_diag', function(source)
    if not Store.CanEdit(source) then
        return print('[vehicle-editor] denied: missing ' .. Config.AcePermission)
    end

    Meta.Diagnose()

    print('[vehicle-editor] attempting a write now...')

    local stateOk, stateErr = State.Save()
    local metaOk, metaErr = Meta.Save()

    print(('[vehicle-editor] %s : %s'):format(State.PATH,
        stateOk and 'SUCCESS' or ('FAILED — ' .. tostring(stateErr))))
    print(('[vehicle-editor] handling.meta : %s'):format(
        metaOk and 'SUCCESS' or ('FAILED — ' .. tostring(metaErr))))
end, false)

---Mirrors a minimal standalone write test, so this resource can be compared
---directly against one on the same server. Everything goes through the same
---hash-invoked natives the editor itself uses.
RegisterCommand('vehedit_testwrite', function(source)
    if not Store.CanEdit(source) then
        return print('[vehicle-editor] denied: missing ' .. Config.AcePermission)
    end

    local marker = ('vehicle-editor write test %d'):format(math.random(1, 1e9))
    local wrote = Meta.writeFile('write_test.txt', marker)
    local readBack = Meta.readFile('write_test.txt')

    print('[vehicle-editor] write test')
    print(('  resource        : %s'):format(GetCurrentResourceName()))
    print(('  SAVE_RESOURCE_FILE returned : %s'):format(tostring(wrote)))
    print(('  read back matches           : %s'):format(tostring(readBack == marker)))

    if type(GetResourcePath) == 'function' then
        local ok, path = pcall(GetResourcePath, GetCurrentResourceName())
        print(('  resource path   : %s'):format(ok and tostring(path) or 'unavailable'))
    end

    if wrote and readBack == marker then
        print('  -> file writing works. Saving will work.')
    else
        print('  -> file writing is broken for this resource.')
        print(('     read back: %s'):format(readBack and ('%d bytes'):format(#readBack) or 'nothing'))
    end
end, false)

---Ask a client to re-run the vanilla capture. Capture has to happen on a
---client because reading handling requires a spawned vehicle, so this targets
---an admin who is in game.
---The controlled experiment. The filename is not the variable -- an earlier
---probe showed declared and undeclared files failing identically -- so this
---compares how the native is reached.
RegisterCommand('vehedit_probe', function(source)
    if not Store.CanEdit(source) then
        return print('[vehicle-editor] denied: missing ' .. Config.AcePermission)
    end

    local results, id = Meta.Probe()

    print('[vehicle-editor] write mechanism probe — marker id ' .. id)
    print('  mechanism                      returned      type      written  on disk  matched')

    local working = {}

    for i = 1, #results do
        local r = results[i]

        print(('  %-30s %-13s %-9s %-8d %-8d %s'):format(
            r.label,
            r.note or tostring(r.raw),
            r.rawType,
            r.written,
            r.onDisk,
            r.matched and 'YES' or 'NO'))

        if r.matched then working[#working + 1] = r.label end
    end

    print('')

    if #working > 0 then
        print(('  These work: %s'):format(table.concat(working, ', ')))
        print('  The editor uses the first working mechanism automatically.')
    else
        print('  No mechanism could write. Note the "type" column: a nil return')
        print('  means the call never reached the native, which is different from')
        print('  a false return meaning the native refused. Check that the server')
        print('  process can write to the path below, and that no antivirus or')
        print('  Controlled Folder Access is blocking FXServer.')
    end

    if type(GetResourcePath) == 'function' then
        local ok, path = pcall(GetResourcePath, GetCurrentResourceName())
        if ok then print(('  resource path: %s'):format(tostring(path))) end
    end
end, false)

RegisterCommand('vehedit_snapshot', function(source)
    if not Store.CanEdit(source) then
        return print('[vehicle-editor] denied: missing ' .. Config.AcePermission)
    end

    local missing = Store.MissingOriginals()
    if #missing == 0 then
        return print('[vehicle-editor] every configured vehicle already has a vanilla snapshot.')
    end

    local target = source

    if target == 0 and type(GetPlayers) == 'function' then
        -- From the console: pick any admin who is in game.
        local ok, players = pcall(GetPlayers)

        if ok and type(players) == 'table' then
            for _, playerId in ipairs(players) do
                local id = tonumber(playerId)
                if id and Store.CanEdit(id) then
                    target = id
                    break
                end
            end
        end
    end

    if target == 0 then
        print('[vehicle-editor] no admin is in game to capture from.')
        print(('[vehicle-editor] join and run /%s, or use this command in game.'):format(Config.Command))
        return
    end

    print(('[vehicle-editor] asking player %d to capture %d vehicle(s)...'):format(target, #missing))
    TriggerClientEvent('vehicleeditor:captureOriginals', target, missing)
end, false)

RegisterCommand('vehedit_reload', function(source)
    if not Store.CanEdit(source) then
        return print('[vehicle-editor] denied: missing ' .. Config.AcePermission)
    end

    Store.tunes = {}
    local loaded = State.Load()
    if loaded == 0 then loaded = Meta.Load() end
    broadcastSync()
    print(('[vehicle-editor] reloaded %d tune(s)'):format(loaded))
end, false)

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------

AddEventHandler('onResourceStart', function(resource)
    if resource ~= GetCurrentResourceName() then return end

    ready = checkLoaded()
    if not ready then return end

    -- Lua 5.4 seeds itself when called with no arguments. Deliberately not
    -- os.time(): this runtime does not ship the full standard library, and a
    -- throw here would abort the rest of onResourceStart.
    math.randomseed()

    -- tunes.json first; handling.meta is only read when there is no state file
    -- yet, which migrates an install from before the split.
    local loaded = State.Load()
    local migrated = false

    if loaded == 0 then
        loaded = Meta.Load()
        migrated = loaded > 0
    end

    -- Make sure every configured vehicle has a store entry even before it has
    -- been touched, so the menu can list it immediately.
    -- (ox_core is initialised after this, so it can read resolved mods.)
    for i = 1, #Config.Vehicles do
        Store.Ensure(Config.Vehicles[i].model)
    end

    print(('[vehicle-editor] ready — %d/%d vehicle(s) restored from %s')
        :format(loaded, #Config.Vehicles, migrated and 'handling.meta' or State.PATH))

    -- Nothing on disk at all is worth saying out loud: it means every edit so
    -- far lived only in memory and did not survive the last restart.
    if loaded == 0 and not Meta.readFile(State.PATH) then
        print(('[vehicle-editor] no %s on disk — nothing has been saved yet.'):format(State.PATH))
        print('[vehicle-editor] if this persists after editing, run vehedit_probe.')
    end

    if migrated then
        print('[vehicle-editor] migrating state into ' .. State.PATH)
        State.Save()
    end

    local missing = Store.MissingOriginals()
    if #missing > 0 then
        print(('[vehicle-editor] %d vehicle(s) need a vanilla snapshot; open /%s in game to capture them.')
            :format(#missing, Config.Command))
    end

    OxCore.Init()

    -- Prove the file is writable at boot rather than discovering it on the
    -- first edit, when an admin has already done work that cannot be kept.
    if Config.WriteMetaOnSave and not Meta.Save() then
        print('[vehicle-editor] startup write test FAILED — edits will not survive a restart until this is fixed.')
    end

    broadcastSync()
end)

---New clients pull the current state themselves via getState, but pushing it on
---join covers clients that loaded before this resource started.
AddEventHandler('playerJoining', function()
    local target = source
    SetTimeout(5000, function()
        TriggerClientEvent('vehicleeditor:sync', target, Store.BuildSync())
    end)
end)
