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

    LoadResourceFile = function(_, path) return harness.files[path] end

    SaveResourceFile = function(_, path, data)
        harness.files[path] = data
        return true
    end

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

    AddEventHandler = function() end
    RegisterCommand = function() end

    -- ox_core is absent under test, so the integration stays dormant and its
    -- pure helpers can still be exercised.
    GetResourceState = function() return 'missing' end
    NetworkGetNetworkIdFromEntity = function(entity) return entity end
    DoesEntityExist = function(entity) return entity ~= nil and entity ~= 0 end

    harness.exported = {}
    exports = setmetatable({}, {
        __call = function(_, name, fn) harness.exported[name] = fn end,
    })

    lib = {
        callback = {
            register = function() end,
        },
        print = { info = function() end },
    }
end

---Load the resource. `server` = false loads only the shared half.
function harness.load(includeServer)
    installNatives()

    dofile(ROOT .. 'config.lua')
    dofile(ROOT .. 'shared/fields.lua')
    dofile(ROOT .. 'shared/util.lua')

    if includeServer ~= false then
        dofile(ROOT .. 'server/store.lua')
        dofile(ROOT .. 'server/state.lua')
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
