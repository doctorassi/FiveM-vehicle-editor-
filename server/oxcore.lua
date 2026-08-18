--[[
    ox_core integration.

    Entirely optional -- without ox_core running, nothing in this file does
    anything and the resource behaves exactly as before.

    Two problems this solves:

    1. Timing. An ox_core vehicle spawns server-side, so clients only pick it up
       on the next pool sweep. Listening for `ox:spawnedVehicle` lets the tune
       land the moment the entity exists.

    2. Ownership. ox_core persists a vehicle's performance mods in its database
       (ox_lib VehicleProperties). Blindly forcing tier mods onto a car a player
       paid to upgrade would fight those saved properties on every spawn, so
       owned and group vehicles are left alone by default -- their handling is
       still tuned to the tier, only the mods are respected.

    Docs: https://overextended.dev/docs/ox_core/Functions/server
]]

OxCore = {
    available = false,
    ---[netId] = { model = string, owned = boolean, id = number? }
    tracked = {},
}

local Ox

--------------------------------------------------------------------------------
-- Detection
--------------------------------------------------------------------------------

local function shouldEnable()
    local setting = (Config.OxCore or {}).Enabled

    if setting == false then return false end
    if setting == true then return true end

    return GetResourceState('ox_core') == 'started'
end

local function loadOx()
    if not shouldEnable() then return false end

    -- The documented entry point; it proxies through exports.ox_core and wraps
    -- vehicles so `:setProperties()` and friends are callable from Lua.
    local ok, result = pcall(require, '@ox_core.lib.init')

    if not ok or type(result) ~= 'table' then
        print(('[vehicle-editor] ox_core is running but its Lua wrapper failed to load (%s); ox_core support is off.')
            :format(tostring(result)))
        return false
    end

    Ox = result
    return true
end

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

---Resolve the configured spawn name for an ox_core vehicle, or nil when the
---vehicle is not one this resource manages.
---@param vehicle table OxVehicle
---@return string?
local function configuredModel(vehicle)
    local model = vehicle and vehicle.model
    if type(model) ~= 'string' then return nil end

    model = model:lower()
    return Config.VehicleByModel[model] and model or nil
end

---A vehicle ox_core saves to its database, i.e. one whose mods belong to a
---player or a group rather than to us.
---@param vehicle table OxVehicle
---@return boolean
local function isOwned(vehicle)
    return (vehicle.owner ~= nil and vehicle.owner ~= false)
        or (vehicle.group ~= nil and vehicle.group ~= false)
end

---Should this resource force its tier mods onto this vehicle?
---@param vehicle table OxVehicle
---@return boolean
function OxCore.ShouldApplyMods(vehicle)
    if not Config.ApplyMods then return false end
    if not isOwned(vehicle) then return true end
    return Config.OxCore.ApplyModsToOwned == true
end

---The tier's mods in ox_lib VehicleProperties form.
---@param model string
---@return table?
function OxCore.TierProperties(model)
    if not Config.VehicleByModel[model] then return nil end
    return Util.ModsToProperties(Store.ResolveMods(model))
end

--------------------------------------------------------------------------------
-- Persisting mods through ox_core
--------------------------------------------------------------------------------

---Write the tier's mods into an ox_core vehicle's saved properties, so garages,
---respawns and the database all agree without the client having to re-force
---them every spawn.
---
---This overwrites whatever mods the vehicle had, so it is never called
---automatically for an owned vehicle -- only for unowned ones, or when a script
---explicitly asks via the ApplyTierProperties export.
---@param vehicle table OxVehicle
---@return boolean applied
function OxCore.PersistProperties(vehicle)
    if not vehicle or not vehicle.entity then return false end

    local model = configuredModel(vehicle)
    if not model then return false end

    local ok, existing = pcall(function() return vehicle:getProperties() end)
    local merged = Util.MergeModProperties(ok and existing or nil, Store.ResolveMods(model))

    local applied = pcall(function() vehicle:setProperties(merged, true) end)
    if not applied then return false end

    -- Only persist to the database for vehicles ox_core actually stores.
    if vehicle.id then pcall(function() vehicle:save() end) end

    Store.debugPrint(('wrote tier mods into ox_core properties for %s'):format(model))
    return true
end

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------

---Tell clients about an ox_core vehicle so they can apply immediately and know
---whether its mods are ours to touch.
---@param netId number
local function announce(netId)
    local entry = OxCore.tracked[netId]
    if not entry then return end

    TriggerClientEvent('vehicleeditor:oxVehicle', -1, netId, entry.model, entry.skipMods)
end

---Register a spawned ox_core vehicle.
---@param entityId number
function OxCore.Track(entityId)
    if not OxCore.available or not DoesEntityExist(entityId) then return end

    local vehicle = Ox.GetVehicle(entityId)
    if not vehicle then return end

    local model = configuredModel(vehicle)
    if not model then return end

    local netId = NetworkGetNetworkIdFromEntity(entityId)
    if not netId or netId == 0 then return end

    local applyMods = OxCore.ShouldApplyMods(vehicle)

    OxCore.tracked[netId] = {
        model = model,
        owned = isOwned(vehicle),
        id = vehicle.id,
        skipMods = not applyMods,
    }

    -- For an unowned vehicle we can bake the mods straight into ox_core's
    -- properties rather than forcing them from every client forever.
    if applyMods and Config.OxCore.PersistModsToProperties and not isOwned(vehicle) then
        OxCore.PersistProperties(vehicle)
        OxCore.tracked[netId].skipMods = true
    end

    if Config.OxCore.ApplyOnSpawn then
        announce(netId)
    end

    Store.debugPrint(('tracking ox_core vehicle %s (netId %d, owned=%s, mods=%s)')
        :format(model, netId, tostring(isOwned(vehicle)), tostring(applyMods)))
end

---@param netId number
function OxCore.Untrack(netId)
    if not OxCore.tracked[netId] then return end

    OxCore.tracked[netId] = nil
    TriggerClientEvent('vehicleeditor:oxVehicleGone', -1, netId)
end

---The netId -> policy map handed to clients on sync, so a late joiner learns
---about vehicles that spawned before they connected.
---@return table
function OxCore.BuildPolicy()
    local policy = {}

    for netId, entry in pairs(OxCore.tracked) do
        policy[tostring(netId)] = { model = entry.model, skipMods = entry.skipMods }
    end

    return policy
end

--------------------------------------------------------------------------------
-- Exports for other scripts
--------------------------------------------------------------------------------

---Create a vehicle through ox_core with this resource's tier mods already in
---its properties, so ox_core saves them rather than us fighting them.
---Mirrors Ox.CreateVehicle(data, coords, heading).
---@param data string|table model name, or an ox_core CreateVehicleData table
---@param coords vector3?
---@param heading number?
---@return table? vehicle, string? err
function OxCore.CreateTieredVehicle(data, coords, heading)
    if not OxCore.available then
        return nil, 'ox_core is not available'
    end

    if type(data) == 'string' then data = { model = data } end
    if type(data) ~= 'table' or type(data.model) ~= 'string' then
        return nil, 'data.model must be a vehicle spawn name'
    end

    local model = data.model:lower()
    if not Config.VehicleByModel[model] then
        return nil, ('"%s" is not listed in Config.Vehicles'):format(model)
    end

    data.properties = Util.MergeModProperties(data.properties, Store.ResolveMods(model))

    local ok, vehicle = pcall(Ox.CreateVehicle, data, coords, heading)
    if not ok then
        return nil, ('ox_core refused to create "%s": %s'):format(model, tostring(vehicle))
    end
    if not vehicle then
        return nil, ('ox_core returned no vehicle for "%s"'):format(model)
    end

    if vehicle.entity then OxCore.Track(vehicle.entity) end

    return vehicle, nil
end

---Spawn a stored vehicle through ox_core and make sure its tune is applied
---immediately. Mirrors Ox.SpawnVehicle(dbId, coords, heading).
---Saved performance mods are left untouched; only the tune is guaranteed.
---@param dbId number|string
---@param coords vector3?
---@param heading number?
---@return table? vehicle, string? err
function OxCore.SpawnTieredVehicle(dbId, coords, heading)
    if not OxCore.available then
        return nil, 'ox_core is not available'
    end

    local ok, vehicle = pcall(Ox.SpawnVehicle, dbId, coords, heading)
    if not ok then
        return nil, ('ox_core refused to spawn %s: %s'):format(tostring(dbId), tostring(vehicle))
    end
    if not vehicle then
        return nil, ('no stored vehicle with id %s'):format(tostring(dbId))
    end

    if vehicle.entity then OxCore.Track(vehicle.entity) end

    return vehicle, nil
end

---Explicitly write the tier's mods into an ox_core vehicle's saved properties.
---This overwrites mods a player may have paid for, so it is never automatic for
---an owned vehicle -- a script has to ask for it.
---@param handle number|string entity id or vin
---@return boolean ok, string? err
function OxCore.ApplyTierProperties(handle)
    if not OxCore.available then
        return false, 'ox_core is not available'
    end

    local vehicle = Ox.GetVehicle(handle)
    if not vehicle then
        return false, 'no ox_core vehicle for that handle'
    end

    if not configuredModel(vehicle) then
        return false, ('"%s" is not listed in Config.Vehicles'):format(tostring(vehicle.model))
    end

    return OxCore.PersistProperties(vehicle), nil
end

---Read-only view of a vehicle's tune, for dealership / garage scripts.
---@param model string
---@return table?
function OxCore.GetVehicleTune(model)
    if type(model) ~= 'string' then return nil end
    model = model:lower()

    local entry = Store.Get(model)
    if not entry then return nil end

    return {
        model = model,
        tier = entry.tier,
        values = Store.ResolveValues(model),
        edits = Util.DeepCopy(entry.values),
        originals = entry.originals and Util.DeepCopy(entry.originals) or nil,
        mods = Store.ResolveMods(model),
        properties = Util.ModsToProperties(Store.ResolveMods(model)),
    }
end

---@param model string
---@return number?
function OxCore.GetVehicleTier(model)
    local entry = Store.Get(model)
    return entry and entry.tier or nil
end

exports('CreateTieredVehicle', function(...) return OxCore.CreateTieredVehicle(...) end)
exports('SpawnTieredVehicle', function(...) return OxCore.SpawnTieredVehicle(...) end)
exports('ApplyTierProperties', function(...) return OxCore.ApplyTierProperties(...) end)
exports('GetVehicleTune', function(...) return OxCore.GetVehicleTune(...) end)
exports('GetVehicleTier', function(...) return OxCore.GetVehicleTier(...) end)

--------------------------------------------------------------------------------
-- Boot
--------------------------------------------------------------------------------

function OxCore.Init()
    OxCore.available = loadOx()

    if not OxCore.available then
        Store.debugPrint('ox_core support disabled')
        return
    end

    print('[vehicle-editor] ox_core detected — spawn hooks and exports are active')

    -- Adopt anything ox_core already has spawned, so a resource restart does not
    -- lose track of live vehicles.
    local ok, vehicles = pcall(Ox.GetVehicles)
    if ok and type(vehicles) == 'table' then
        for i = 1, #vehicles do
            local vehicle = vehicles[i]
            if vehicle and vehicle.entity then OxCore.Track(vehicle.entity) end
        end
    end
end

AddEventHandler('ox:spawnedVehicle', function(entityId)
    if not OxCore.available then return end
    OxCore.Track(entityId)
end)

AddEventHandler('ox:despawnVehicle', function(entityId)
    if not OxCore.available then return end
    if not entityId or not DoesEntityExist(entityId) then return end

    local netId = NetworkGetNetworkIdFromEntity(entityId)
    if netId and netId ~= 0 then OxCore.Untrack(netId) end
end)
