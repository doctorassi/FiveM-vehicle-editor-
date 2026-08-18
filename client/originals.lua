--[[
    Vanilla ("original") value capture.

    There is no native that reads handling off a model without an instance, so a
    throwaway vehicle is spawned far under the map, read, and deleted. The handle
    is registered in `Originals.ignored` first: if the apply loop touched it we
    would be snapshotting our own tune and permanently losing the real originals.

    Values are converted to handling.meta units on the way out, which is the unit
    everything else in this resource stores and displays.
]]

Originals = {
    ---[entity] = true, vehicles the apply loop must not touch.
    ignored = {},
    busy = false,
}

local SNAPSHOT_COORDS = vec3(0.0, 0.0, -500.0)

local function readRuntime(vehicle, field)
    if field.type == 'vector' then
        local value = GetVehicleHandlingVector(vehicle, 'CHandlingData', field.name)
        return { x = value.x + 0.0, y = value.y + 0.0, z = value.z + 0.0 }
    end

    if field.type == 'int' or field.type == 'flags' then
        return GetVehicleHandlingInt(vehicle, 'CHandlingData', field.name)
    end

    return GetVehicleHandlingFloat(vehicle, 'CHandlingData', field.name)
end

---Read every field off a live vehicle and convert to handling.meta units.
---@param vehicle number
---@return table
function Originals.ReadVehicle(vehicle)
    -- fDriveBiasFront alone is ambiguous (FWD and 50/50 AWD both read 1.0);
    -- the rear value disambiguates. Guarded because not every build exposes it.
    local rearBias
    local ok, value = pcall(GetVehicleHandlingFloat, vehicle, 'CHandlingData', 'fDriveBiasRear')
    if ok and type(value) == 'number' then
        rearBias = value
    end

    local snapshot = {}

    for i = 1, #Fields.All do
        local field = Fields.All[i]
        local runtime = readRuntime(vehicle, field)

        if field.type == 'vector' then
            snapshot[field.name] = runtime
        elseif field.type == 'flags' or field.type == 'int' then
            snapshot[field.name] = runtime
        else
            snapshot[field.name] = Util.ToMeta(field, runtime, field.special == 'driveBias' and rearBias or nil)
        end
    end

    return snapshot
end

---Spawn, read and delete a temporary vehicle for `model`.
---@param model string
---@return table? snapshot, string? err
function Originals.Snapshot(model)
    local hash = joaat(model)

    if not IsModelInCdimage(hash) or not IsModelAVehicle(hash) then
        return nil, ('"%s" is not a vehicle model on this server'):format(model)
    end

    RequestModel(hash)
    local deadline = GetGameTimer() + 10000
    while not HasModelLoaded(hash) do
        if GetGameTimer() > deadline then
            SetModelAsNoLongerNeeded(hash)
            return nil, ('timed out loading "%s"'):format(model)
        end
        Wait(0)
    end

    local vehicle = CreateVehicle(hash, SNAPSHOT_COORDS.x, SNAPSHOT_COORDS.y, SNAPSHOT_COORDS.z, 0.0, false, false)
    if not vehicle or vehicle == 0 or not DoesEntityExist(vehicle) then
        SetModelAsNoLongerNeeded(hash)
        return nil, ('could not spawn "%s"'):format(model)
    end

    Originals.ignored[vehicle] = true

    SetEntityCollision(vehicle, false, false)
    SetEntityVisible(vehicle, false, false)
    FreezeEntityPosition(vehicle, true)

    -- One frame so the handling data is fully initialised before it is read.
    Wait(0)

    local snapshot = Originals.ReadVehicle(vehicle)

    Originals.ignored[vehicle] = nil
    DeleteEntity(vehicle)
    SetModelAsNoLongerNeeded(hash)

    return snapshot, nil
end

---Snapshot a list of models and hand them to the server.
---@param models string[]
---@return number captured, string[] failures
function Originals.CaptureAndSubmit(models)
    if Originals.busy or not models or #models == 0 then
        return 0, {}
    end

    Originals.busy = true

    local snapshots, failures = {}, {}
    local captured = 0

    for i = 1, #models do
        local model = models[i]
        local snapshot, err = Originals.Snapshot(model)

        if snapshot then
            snapshots[model] = snapshot
            captured = captured + 1
        else
            failures[#failures + 1] = ('%s (%s)'):format(model, err or 'unknown error')
        end

        Wait(0)
    end

    Originals.busy = false

    if captured == 0 then
        return 0, failures
    end

    local ok, err, stored = lib.callback.await('vehicleeditor:submitOriginals', false, snapshots)
    if not ok then
        failures[#failures + 1] = err or 'server rejected the snapshot'
        return 0, failures
    end

    return stored or captured, failures
end
