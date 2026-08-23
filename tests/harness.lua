--[[
    Loads the resource's shared + server Lua under plain Lua 5.4 with the CFX
    natives stubbed, so the maths and the handling.meta round trip can be tested
    without a running server.
]]

local harness = {}

local ROOT = (arg and arg[0] or 'tests/run.lua'):match('^(.*)tests[/\\][^/\\]*$') or './'

---In-memory stand-in for the resource's file system.
harness.files = {}

local function installNatives()
    json = dofile(ROOT .. 'tests/json.lua')

    GetCurrentResourceName = function() return 'fivem-vehicle-editor' end

    -- Both IO mechanisms are modelled, because the resource prefers the
    -- globals and falls back to Citizen.InvokeNative.
    local SAVE_RESOURCE_FILE = 0xA09E7E7B
    local LOAD_RESOURCE_FILE = 0x76A9EE1F

    ---Make every write fail outright.
    harness.writesFail = false

    ---Filenames whose writes are silently discarded while the call still
    ---reports success -- the reported host's behaviour.
    harness.silentlyDiscard = {}

    ---Remove the globals entirely, forcing the InvokeNative fallback.
    harness.globalsMissing = false

    ---Make InvokeNative return nil, as it does on the reported host. `nil ~= 0`
    ---is true in Lua, which is what made every save report success.
    harness.invokeNativeReturnsNil = false

    ---Which mechanism actually performed the last write.
    harness.lastMechanism = nil

    local function performWrite(path, data, mechanism)
        if harness.writesFail then return false end
        harness.lastMechanism = mechanism
        if harness.silentlyDiscard[path] then return true end
        harness.files[path] = data
        return true
    end

    local function installGlobals()
        if harness.globalsMissing then
            SaveResourceFile, LoadResourceFile = nil, nil
            return
        end

        SaveResourceFile = function(_, path, data)
            return performWrite(path, data, 'SaveResourceFile')
        end

        LoadResourceFile = function(_, path) return harness.files[path] end
    end

    ---Expose the globals the way CFX does -- through an __index metamethod on
    ---the global table rather than as raw entries -- so code using rawget sees
    ---nothing, exactly as it did on the reported server.
    function harness.installGlobalsViaMetatable()
        local backing = {}
        SaveResourceFile = nil
        LoadResourceFile = nil

        backing.SaveResourceFile = function(_, path, data)
            return performWrite(path, data, 'SaveResourceFile')
        end
        backing.LoadResourceFile = function(_, path) return harness.files[path] end

        setmetatable(_G, { __index = backing })
        harness.metatableBacked = true
    end

    function harness.clearGlobalMetatable()
        setmetatable(_G, nil)
        harness.metatableBacked = false
    end

    harness.installGlobals = installGlobals
    installGlobals()

    Citizen = {
        ResultAsInteger = function() return '__resultAsInteger' end,
        ResultAsString = function() return '__resultAsString' end,
        InvokeNative = function(hash, ...)
            local args = { ... }

            if hash == SAVE_RESOURCE_FILE then
                if harness.invokeNativeReturnsNil then return nil end
                return performWrite(args[2], args[3], 'InvokeNative') and 1 or 0
            end

            if hash == LOAD_RESOURCE_FILE then
                return harness.files[args[2]]
            end

            error(('unexpected native 0x%X'):format(hash))
        end,
    }

    ---Ace state the tests can flip.
    harness.aceAllowed = {}
    IsPlayerAceAllowed = function(source, ace)
        return harness.aceAllowed[source .. '|' .. ace] == true
    end

    ---Timers are collected rather than run; nothing under test needs them to fire.
    harness.timers = {}
    SetTimeout = function(delay, fn)
        harness.timers[#harness.timers + 1] = { delay = delay, fn = fn }
    end

    harness.broadcasts = {}
    TriggerClientEvent = function(name, target, payload)
        harness.broadcasts[#harness.broadcasts + 1] = { name = name, target = target, payload = payload }
    end

    -- Recorded so tests can fire onResourceStart and exercise the real startup
    -- path, which is where every load-order failure has surfaced.
    harness.handlers = {}
    AddEventHandler = function(name, fn)
        harness.handlers[name] = harness.handlers[name] or {}
        table.insert(harness.handlers[name], fn)
    end

    harness.commands = {}
    RegisterCommand = function(name, fn) harness.commands[name] = fn end

    -- ox_core is absent under test, so the integration stays dormant and its
    -- pure helpers can still be exercised.
    GetResourceState = function() return 'missing' end
    GetPlayers = function() return {} end
    NetworkGetNetworkIdFromEntity = function(entity) return entity end
    DoesEntityExist = function(entity) return entity ~= nil and entity ~= 0 end

    harness.exported = {}
    exports = setmetatable({}, {
        __call = function(_, name, fn) harness.exported[name] = fn end,
    })

    harness.callbacks = {}
    lib = {
        callback = {
            register = function(name, fn) harness.callbacks[name] = fn end,
        },
        print = { info = function() end },
    }
end

---Install stubs for the handling natives so client/originals.lua can run
---headlessly. `harness.unreadable[field] = true` makes a field read back nil,
---mimicking a build whose natives will not expose it.
function harness.installHandlingNatives()
    harness.unreadable = {}
    harness.vehicles = {}
    harness.nextEntity = 1000

    local function value(field)
        if harness.unreadable[field] then return nil end
        return 1.5
    end

    GetVehicleHandlingFloat = function(_, _, field) return value(field) end
    GetVehicleHandlingInt = function(_, _, field)
        local v = value(field)
        return v and 5 or nil
    end
    GetVehicleHandlingVector = function(_, _, field)
        if harness.unreadable[field] then return nil end
        return { x = 0.1, y = 0.2, z = 0.3 }
    end

    joaat = function(text) return #text end
    IsModelInCdimage = function() return true end
    IsModelAVehicle = function() return true end
    RequestModel = function() end
    HasModelLoaded = function() return true end
    SetModelAsNoLongerNeeded = function() end
    GetGameTimer = function() return 0 end
    Wait = function() end
    DoesEntityExist = function(e) return e ~= nil and e ~= 0 end
    SetEntityCollision = function() end
    SetEntityVisible = function() end
    FreezeEntityPosition = function() end
    DeleteEntity = function(e) harness.vehicles[e] = nil end
    RegisterNetEvent = function() end
    vec3 = function(x, y, z) return { x = x, y = y, z = z } end

    ---Models named here fail to spawn.
    harness.unspawnable = {}
    CreateVehicle = function(hash)
        if harness.unspawnable[hash] then return 0 end
        harness.nextEntity = harness.nextEntity + 1
        harness.vehicles[harness.nextEntity] = true
        return harness.nextEntity
    end

    ---Captures what the client submitted.
    harness.submitted = nil
    lib.callback = lib.callback or {}
    lib.callback.await = function(_, _, snapshots, failures, skipped)
        harness.submitted = { snapshots = snapshots, failures = failures, skipped = skipped }
        local count = 0
        for _ in pairs(snapshots or {}) do count = count + 1 end
        return true, nil, count
    end
    lib.notify = function() end
end

---Fire every handler registered for an event.
function harness.fire(event, ...)
    local handlers = harness.handlers[event]
    if not handlers then return 0 end

    for i = 1, #handlers do handlers[i](...) end
    return #handlers
end

---Load the resource. `server` = false loads only the shared half.
function harness.load(includeServer)
    installNatives()

    dofile(ROOT .. 'config.lua')
    dofile(ROOT .. 'shared/fields.lua')
    dofile(ROOT .. 'shared/util.lua')

    if includeServer ~= false then
        dofile(ROOT .. 'server/store.lua')
        dofile(ROOT .. 'server/meta.lua')
        dofile(ROOT .. 'server/oxcore.lua')
    end
end

---Fabricate a plausible vanilla snapshot so tests do not need a game client.
---Values are in handling.meta units.
---@param seed number
---@return table
function harness.fakeOriginals(seed)
    local originals = {}

    for i = 1, #Fields.All do
        local field = Fields.All[i]

        if field.type == 'vector' then
            originals[field.name] = { x = 0.1 * seed, y = 0.2 * seed, z = 0.3 * seed }
        elseif field.type == 'flags' then
            originals[field.name] = 0x440010
        elseif field.type == 'int' then
            originals[field.name] = 5 + seed
        else
            local editable = Fields.EditableByName[field.name]
            if editable then
                -- Sit in the middle of the allowed range so clamping is not
                -- accidentally exercised by the fixture itself.
                originals[field.name] = editable.min + (editable.max - editable.min) * 0.25
            else
                originals[field.name] = 1.0 + seed * 0.1
            end
        end
    end

    return originals
end

return harness
