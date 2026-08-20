--[[
    Server entry point: startup load, ox_lib callbacks, autosave, sync.
]]

local saveScheduled = false

---Coalesce rapid edits into a single file write. Every mutation calls this, so
---an edit is on disk within a second of being made -- there is no "unsaved"
---state to lose.
local function scheduleSave()
    if not Config.WriteMetaOnSave or saveScheduled then return end

    saveScheduled = true
    SetTimeout(1000, function()
        saveScheduled = false

        local ok = Meta.Save()
        if not ok then
            -- "Edits are always saved" is the whole point, so a failed autosave
            -- is told to everyone who can act on it rather than only the log.
            TriggerClientEvent('vehicleeditor:saveFailed', -1, Meta.lastError)
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

    local ok, err = Meta.Save()
    if not ok then
        return false, ('Could not write data/handling.meta: %s'):format(err or 'unknown error')
    end

    return true, nil
end)

---Throw away in-memory state and re-read the file from disk.
lib.callback.register('vehicleeditor:reload', function(source)
    if not Store.CanEdit(source) then
        return false, 'You do not have permission to edit vehicles.'
    end

    Store.tunes = {}
    local loaded = Meta.Load()
    broadcastSync()

    return true, nil, loaded
end)

---A client reporting the vanilla values it read off a freshly spawned vehicle.
---Only ever accepted once per model (Store.SetOriginals refuses to overwrite),
---so a client cannot rewrite the originals of an already-tuned vehicle.
lib.callback.register('vehicleeditor:submitOriginals', function(source, snapshots)
    if not Store.CanEdit(source) then
        return false, 'You do not have permission to edit vehicles.'
    end

    if type(snapshots) ~= 'table' then
        return false, 'invalid snapshot payload'
    end

    local stored = 0
    for model, originals in pairs(snapshots) do
        if Config.VehicleByModel[type(model) == 'string' and model:lower() or ''] then
            if Store.SetOriginals(model, originals) then
                stored = stored + 1
            end
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
    print('[vehicle-editor] ' .. (Meta.Save() and 'saved data/handling.meta' or 'save failed'))
end, false)

RegisterCommand('vehedit_diag', function(source)
    if not Store.CanEdit(source) then
        return print('[vehicle-editor] denied: missing ' .. Config.AcePermission)
    end

    print('[vehicle-editor] --- save diagnostics ---')
    for _, line in ipairs(Meta.Diagnose()) do
        print('[vehicle-editor]   ' .. line)
    end

    print('[vehicle-editor] attempting a write now...')
    local ok, err = Meta.Save()
    print(('[vehicle-editor] result: %s'):format(ok and 'SUCCESS' or ('FAILED — ' .. tostring(err))))
end, false)

RegisterCommand('vehedit_reload', function(source)
    if not Store.CanEdit(source) then
        return print('[vehicle-editor] denied: missing ' .. Config.AcePermission)
    end

    Store.tunes = {}
    local loaded = Meta.Load()
    broadcastSync()
    print(('[vehicle-editor] reloaded %d tune(s) from data/handling.meta'):format(loaded))
end, false)

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------

AddEventHandler('onResourceStart', function(resource)
    if resource ~= GetCurrentResourceName() then return end

    -- Guarded: this runtime does not ship the whole standard library, and a
    -- throw here would abort the rest of onResourceStart.
    if type(os) == 'table' and type(os.time) == 'function' then
        math.randomseed(os.time())
    else
        pcall(math.randomseed)
    end

    local loaded = Meta.Load()

    -- Make sure every configured vehicle has a store entry even before it has
    -- been touched, so the menu can list it immediately.
    -- (ox_core is initialised after this, so it can read resolved mods.)
    for i = 1, #Config.Vehicles do
        Store.Ensure(Config.Vehicles[i].model)
    end

    print(('[vehicle-editor] ready — %d/%d vehicle(s) restored from data/handling.meta')
        :format(loaded, #Config.Vehicles))

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
