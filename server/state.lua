--[[
    Editor state persistence.

    This is the source of truth, and it is a plain JSON file written with
    SaveResourceFile -- the ordinary FiveM persistence route.

    It is deliberately NOT declared in fxmanifest's `files {}`. handling.meta is,
    because the game has to load it as HANDLING_FILE, and a file the resource
    system owns is not reliably writable at runtime: writes to it can simply not
    land, leaving the original on disk. Keeping state in a file nothing else
    claims removes that failure mode entirely.

    handling.meta is still generated (see server/meta.lua) so the game applies
    tunes natively at startup, but it is now a bonus rather than the only copy.
    If it cannot be written, nothing is lost -- the state is here, and clients
    apply it through the handling natives regardless.
]]

State = {}

local RESOURCE = GetCurrentResourceName()
local STATE_PATH = 'tunes.json'
local FORMAT_VERSION = 1

---Last failure reason, surfaced to the menu.
State.lastError = nil

---Serialise the store into the on-disk shape.
---@return table
function State.Build()
    local payload = { version = FORMAT_VERSION, tunes = {} }

    for model, entry in pairs(Store.tunes) do
        payload.tunes[model] = {
            tier = entry.tier,
            originals = entry.originals,
            edits = entry.values,
            mods = entry.mods,
        }
    end

    return payload
end

---Write the state file.
---
---Verified by reading the file back rather than by trusting the return value:
---builds disagree on whether a good write reports success, and a write that
---silently does not land is the exact failure this file exists to catch.
---@return boolean ok, string? err
function State.Save()
    local encoded = json.encode(State.Build())

    local reported = SaveResourceFile(RESOURCE, STATE_PATH, encoded, -1)
    local readBack = LoadResourceFile(RESOURCE, STATE_PATH)

    if readBack and #readBack == #encoded then
        State.lastError = nil
        Store.debugPrint(('wrote %s (%d bytes)'):format(STATE_PATH, #encoded))
        return true, nil
    end

    local err
    if not readBack then
        err = ('SaveResourceFile("%s", "%s") produced no file (returned %s)')
            :format(RESOURCE, STATE_PATH, tostring(reported))
    else
        err = ('%s is %d bytes on disk but %d were written'):format(STATE_PATH, #readBack, #encoded)
    end

    State.lastError = err
    print('[vehicle-editor] FAILED to save ' .. STATE_PATH .. ': ' .. err)
    Meta.Diagnose()

    return false, err
end

---Read the state file back into the store.
---@return number loaded
function State.Load()
    local raw = LoadResourceFile(RESOURCE, STATE_PATH)
    if not raw or raw == '' then return 0 end

    local ok, payload = pcall(json.decode, raw)
    if not ok or type(payload) ~= 'table' or type(payload.tunes) ~= 'table' then
        print(('[vehicle-editor] %s is unreadable and was ignored: %s')
            :format(STATE_PATH, tostring(payload)))
        return 0
    end

    local loaded = 0

    for model, parsed in pairs(payload.tunes) do
        -- Only adopt vehicles still in the config; one removed from
        -- Config.Vehicles should stop being managed, not linger forever.
        if type(model) == 'string' and Config.VehicleByModel[model:lower()] and type(parsed) == 'table' then
            Store.tunes[model:lower()] = {
                model = model:lower(),
                tier = math.min(math.max(tonumber(parsed.tier) or 1, Config.MinTier), Config.MaxTier),
                values = type(parsed.edits) == 'table' and parsed.edits or {},
                mods = type(parsed.mods) == 'table' and parsed.mods or {},
                originals = type(parsed.originals) == 'table' and parsed.originals or nil,
            }
            loaded = loaded + 1
        end
    end

    Store.Bump()
    Store.debugPrint(('loaded %d tune(s) from %s'):format(loaded, STATE_PATH))

    return loaded
end

State.PATH = STATE_PATH
