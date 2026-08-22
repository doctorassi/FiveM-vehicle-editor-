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

---Read one field off a vehicle, returning nil rather than raising when the
---native will not produce it.
---
---This is deliberate and load-bearing: not every field in the schema is exposed
---by the handling natives on every build, and the previous version did
---`value.x + 0.0` and arithmetic on the result with no nil check. A single
---unreadable field raised, which killed the capture of every vehicle.
local function readRuntime(vehicle, field)
    if field.type == 'vector' then
        local ok, value = pcall(GetVehicleHandlingVector, vehicle, 'CHandlingData', field.name)
        if not ok or type(value) ~= 'table' and type(value) ~= 'vector3' then return nil end
        if value.x == nil or value.y == nil or value.z == nil then return nil end

        return { x = value.x + 0.0, y = value.y + 0.0, z = value.z + 0.0 }
    end

    local reader = (field.type == 'int' or field.type == 'flags')
        and GetVehicleHandlingInt
        or GetVehicleHandlingFloat

    local ok, value = pcall(reader, vehicle, 'CHandlingData', field.name)
    if not ok or type(value) ~= 'number' then return nil end
    -- nan would be written straight into handling.meta.
    if value ~= value then return nil end

    return value
end

---Read every field off a live vehicle and convert to handling.meta units.
---@param vehicle number
---@return table snapshot, string[] skipped names of fields that would not read
function Originals.ReadVehicle(vehicle)
    -- fDriveBiasFront alone is ambiguous (FWD and 50/50 AWD both read 1.0);
    -- the rear value disambiguates. Guarded because not every build exposes it.
    local rearBias
    local ok, value = pcall(GetVehicleHandlingFloat, vehicle, 'CHandlingData', 'fDriveBiasRear')
    if ok and type(value) == 'number' then
        rearBias = value
    end

    local snapshot, skipped = {}, {}

    for i = 1, #Fields.All do
        local field = Fields.All[i]
        local runtime = readRuntime(vehicle, field)

        if runtime == nil then
            skipped[#skipped + 1] = field.name
        elseif field.type == 'vector' or field.type == 'flags' or field.type == 'int' then
            snapshot[field.name] = runtime
        else
            snapshot[field.name] = Util.ToMeta(field, runtime,
                field.special == 'driveBias' and rearBias or nil)
        end
    end

    return snapshot, skipped
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

    -- Read under pcall so the temporary vehicle is always cleaned up; leaking a
    -- frozen invisible car under the map on every failure would be worse than
    -- the failure itself.
    local ok, snapshot, skipped = pcall(Originals.ReadVehicle, vehicle)

    Originals.ignored[vehicle] = nil
    DeleteEntity(vehicle)
    SetModelAsNoLongerNeeded(hash)

    if not ok then
        return nil, ('reading "%s" failed: %s'):format(model, tostring(snapshot))
    end

    -- A missing physics field means the entry would be written incomplete and
    -- the game would default real handling values, so the vehicle is refused.
    local missing = {}
    for i = 1, #Fields.Required do
        if snapshot[Fields.Required[i]] == nil then
            missing[#missing + 1] = Fields.Required[i]
        end
    end

    if #missing > 0 then
        return nil, ('"%s" is missing %d required field(s): %s')
            :format(model, #missing, table.concat(missing, ', ', 1, math.min(#missing, 5)))
    end

    return snapshot, nil, skipped
end

---Snapshot a list of models and hand them to the server.
---@param models string[]
---@return number captured, string[] failures
---Snapshot a list of models and hand them to the server.
---
---Each model is isolated: one that cannot be read is recorded as a failure and
---the rest still get captured. `busy` is cleared on every exit path, including
---an error -- leaving it latched was what made a single bad field disable the
---editor permanently and silently, since every later attempt then returned
---"nothing to do" instead of retrying.
---@param models string[]
---@return number captured, string[] failures, string[] skippedFields
function Originals.CaptureAndSubmit(models)
    if not models or #models == 0 then
        return 0, {}, {}
    end

    if Originals.busy then
        return 0, { 'a capture is already running' }, {}
    end

    Originals.busy = true

    local snapshots, failures, skippedFields = {}, {}, {}
    local captured = 0

    local ok, err = pcall(function()
        for i = 1, #models do
            local model = models[i]

            local success, snapshot, snapErr, skipped = pcall(Originals.Snapshot, model)

            if not success then
                failures[#failures + 1] = ('%s (%s)'):format(model, tostring(snapshot))
            elseif snapshot then
                snapshots[model] = snapshot
                captured = captured + 1

                if skipped then
                    for j = 1, #skipped do
                        skippedFields[skipped[j]] = true
                    end
                end
            else
                failures[#failures + 1] = ('%s (%s)'):format(model, snapErr or 'unknown error')
            end

            Wait(0)
        end
    end)

    Originals.busy = false

    if not ok then
        failures[#failures + 1] = ('capture aborted: %s'):format(tostring(err))
    end

    -- Flatten the skipped-field set for reporting.
    local skippedList = {}
    for name in pairs(skippedFields) do skippedList[#skippedList + 1] = name end
    table.sort(skippedList)

    if captured == 0 then
        -- Still tell the server, so the failures reach the console.
        pcall(function()
            lib.callback.await('vehicleeditor:submitOriginals', false, {}, failures, skippedList)
        end)
        return 0, failures, skippedList
    end

    local sent, sendErr, stored =
        lib.callback.await('vehicleeditor:submitOriginals', false, snapshots, failures, skippedList)

    if not sent then
        failures[#failures + 1] = sendErr or 'server rejected the snapshot'
        return 0, failures, skippedList
    end

    return stored or captured, failures, skippedList
end

---Capture a single model on demand, used when opening one vehicle's menu.
---@param model string
---@return boolean ok, string? err
function Originals.CaptureOne(model)
    local captured, failures = Originals.CaptureAndSubmit({ model })
    if captured > 0 then return true, nil end
    return false, failures[1] or 'capture failed'
end

---Server-triggered capture, for the vehedit_snapshot command.
RegisterNetEvent('vehicleeditor:captureOriginals', function(models)
    if type(models) ~= 'table' or #models == 0 then return end

    local captured, failures = Originals.CaptureAndSubmit(models)

    lib.notify({
        title = 'Vehicle Editor',
        description = ('Captured %d of %d vehicle(s).'):format(captured, #models),
        type = captured > 0 and 'success' or 'error',
    })

    if #failures > 0 then
        lib.notify({
            title = 'Vehicle Editor',
            description = ('%d failed — see the server console.'):format(#failures),
            type = 'error',
            duration = 8000,
        })
    end
end)
