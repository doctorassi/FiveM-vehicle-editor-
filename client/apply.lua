--[[
    Live application.

    handling.meta only takes effect when the resource starts, so anything saved
    while the server is running would otherwise need a restart. This sweeps the
    vehicle pool and pushes the same values through the handling natives, keyed
    off the server's version counter -- a save takes effect for every player
    within one sweep.
]]

Apply = {}

---Server state: { version = number, tunes = { [model] = { values, mods, ... } } }
Tunes = { version = -1, tunes = {} }

---[entity] = version the handling was applied at.
local handlingApplied = {}
---[entity] = version the mods were applied at. Tracked separately because mods
---need network ownership and handling does not.
local modsApplied = {}
---[modelHash] = spawn name, rebuilt whenever the config-driven tune list changes.
local modelIndex = {}

local function rebuildModelIndex()
    modelIndex = {}
    for model in pairs(Tunes.tunes) do
        modelIndex[joaat(model)] = model
    end
end

--------------------------------------------------------------------------------
-- Handling
--------------------------------------------------------------------------------

---Push a full field set (in handling.meta units) onto a vehicle.
---@param vehicle number
---@param values table<string, any>
function Apply.Handling(vehicle, values)
    for i = 1, #Fields.All do
        local field = Fields.All[i]
        local value = values[field.name]

        if value ~= nil then
            if field.type == 'vector' then
                SetVehicleHandlingVector(vehicle, 'CHandlingData', field.name,
                    vec3(value.x or 0.0, value.y or 0.0, value.z or 0.0))
            elseif field.type == 'int' then
                SetVehicleHandlingInt(vehicle, 'CHandlingData', field.name, math.floor(value))
            elseif field.type == 'flags' then
                -- Deliberately skipped: flags describe what the model *is*
                -- (drivetrain layout, hydraulics, ...) and are not safely
                -- swappable on an already-spawned vehicle. They are still
                -- written to handling.meta faithfully.
            else
                SetVehicleHandlingFloat(vehicle, 'CHandlingData', field.name,
                    Util.ToRuntime(field, value) + 0.0)
            end
        end
    end
end

--------------------------------------------------------------------------------
-- Performance mods
--------------------------------------------------------------------------------

---@param vehicle number
---@param mods table
function Apply.Mods(vehicle, mods)
    SetVehicleModKit(vehicle, 0)

    for i = 1, #Config.ModTypes do
        local modType = Config.ModTypes[i]
        local level = mods[modType.id]

        if level ~= nil and level >= 0 then
            -- Different models carry different numbers of upgrades, so clamp to
            -- what this one actually has rather than trusting the config.
            local available = GetNumVehicleMods(vehicle, modType.modType)
            if available > 0 then
                SetVehicleMod(vehicle, modType.modType, math.min(level, available - 1), false)
            end
        elseif level ~= nil then
            RemoveVehicleMod(vehicle, modType.modType)
        end
    end

    ToggleVehicleMod(vehicle, Config.TurboModType, mods.turbo and true or false)
end

--------------------------------------------------------------------------------
-- Sweep
--------------------------------------------------------------------------------

---@param vehicle number
---@param force boolean? re-apply even if this version was already applied
function Apply.ToVehicle(vehicle, force)
    if Originals.ignored[vehicle] then return end
    if not DoesEntityExist(vehicle) then return end

    local model = modelIndex[GetEntityModel(vehicle)]
    if not model then return end

    local tune = Tunes.tunes[model]
    if not tune or not tune.values then return end

    if force or handlingApplied[vehicle] ~= Tunes.version then
        Apply.Handling(vehicle, tune.values)
        handlingApplied[vehicle] = Tunes.version
    end

    if Config.ApplyMods and tune.mods and modsApplied[vehicle] ~= Tunes.version then
        -- Mods only stick on a vehicle this client owns; retried next sweep
        -- otherwise, which is why this is not marked applied on failure.
        if NetworkHasControlOfEntity(vehicle) then
            Apply.Mods(vehicle, tune.mods)
            modsApplied[vehicle] = Tunes.version
        end
    end
end

---Drop cache entries for vehicles that no longer exist.
local function prune(seen)
    for vehicle in pairs(handlingApplied) do
        if not seen[vehicle] then handlingApplied[vehicle] = nil end
    end
    for vehicle in pairs(modsApplied) do
        if not seen[vehicle] then modsApplied[vehicle] = nil end
    end
end

CreateThread(function()
    local sweeps = 0

    while true do
        Wait(Config.ApplyInterval)

        if next(modelIndex) then
            local pool = GetGamePool('CVehicle')
            local seen = {}

            for i = 1, #pool do
                local vehicle = pool[i]
                seen[vehicle] = true
                Apply.ToVehicle(vehicle)
            end

            sweeps = sweeps + 1
            if sweeps % 20 == 0 then
                prune(seen)
            end
        end
    end
end)

--------------------------------------------------------------------------------
-- Sync
--------------------------------------------------------------------------------

---@param payload table
function Apply.Receive(payload)
    if type(payload) ~= 'table' then return end

    Tunes = payload
    Tunes.tunes = Tunes.tunes or {}
    rebuildModelIndex()

    -- The version moved, so every cached entity is stale; the next sweep
    -- re-applies. Clearing here rather than comparing per-entity keeps a reset
    -- (which removes values) as cheap as an edit.
    handlingApplied = {}
    modsApplied = {}

    -- Anything the player is sitting in should not wait for the sweep.
    local current = GetVehiclePedIsIn(PlayerPedId(), false)
    if current ~= 0 then
        Apply.ToVehicle(current, true)
    end
end

RegisterNetEvent('vehicleeditor:sync', Apply.Receive)

CreateThread(function()
    -- Pull state once the player is actually in the world; the server also
    -- pushes on join, whichever lands first wins.
    while not NetworkIsSessionStarted() do Wait(250) end

    local state = lib.callback.await('vehicleeditor:getState', false)
    if state and state.sync then
        Apply.Receive(state.sync)
    end
end)
