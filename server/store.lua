--[[
    Authoritative tune store.

    Everything a client sends passes through here and is re-validated: the ace
    check, the "is this model even in Config.Vehicles" check and the per-field
    clamp all live on this side. The client menu is a view, never a source of
    truth.
]]

Store = {
    ---[model] = { model, tier, values = {}, mods = {}, originals = {} }
    tunes = {},
    ---Bumped on every mutation. Clients drop their applied-cache when it moves,
    ---which is what makes a save take effect live for everyone.
    version = 0,
}

local function debugPrint(...)
    if Config.Debug then
        print('[vehicle-editor]', ...)
    end
end

Store.debugPrint = debugPrint

---@param source number
---@return boolean
function Store.CanEdit(source)
    -- Console (source 0) is always allowed so server commands keep working.
    if source == 0 then return true end
    return IsPlayerAceAllowed(source, Config.AcePermission)
end

---@param model string
---@return table? entry, string? err
function Store.Ensure(model)
    if type(model) ~= 'string' then
        return nil, 'model must be a string'
    end

    model = model:lower()

    local configured = Config.VehicleByModel[model]
    if not configured then
        return nil, ('"%s" is not listed in Config.Vehicles'):format(model)
    end

    local entry = Store.tunes[model]
    if not entry then
        entry = {
            model = model,
            tier = configured.tier,
            values = {},
            mods = {},
            originals = nil,
        }
        Store.tunes[model] = entry
    end

    return entry, nil
end

---@param model string
---@return table?
function Store.Get(model)
    if type(model) ~= 'string' then return nil end
    return Store.tunes[model:lower()]
end

function Store.Bump()
    Store.version = Store.version + 1
    return Store.version
end

--------------------------------------------------------------------------------
-- Originals
--------------------------------------------------------------------------------

---Store a vanilla snapshot. Ignored if we already have one -- re-snapshotting a
---vehicle that already has a tune applied would overwrite the real originals
---with tuned values.
---@param model string
---@param originals table<string, any>
---@return boolean stored
function Store.SetOriginals(model, originals)
    local entry = Store.Ensure(model)
    if not entry then return false, 'not a configured vehicle' end
    if type(originals) ~= 'table' then return false, 'snapshot is not a table' end
    if entry.originals then return false, nil end

    local clean = {}
    for i = 1, #Fields.All do
        local field = Fields.All[i]
        local value = originals[field.name]
        if field.type == 'vector' then
            if type(value) == 'table' and value.x and value.y and value.z then
                clean[field.name] = { x = value.x + 0.0, y = value.y + 0.0, z = value.z + 0.0 }
            end
        elseif value ~= nil then
            local number = tonumber(value)
            if number and number == number and number ~= math.huge and number ~= -math.huge then
                clean[field.name] = number
            end
        end
    end

    -- A snapshot missing a physics field would be written to handling.meta
    -- incomplete, and the game would silently default whatever is absent. Refuse
    -- it and say which fields are short, rather than storing something that
    -- produces a subtly wrong car.
    local missing = {}
    for i = 1, #Fields.Required do
        if clean[Fields.Required[i]] == nil then
            missing[#missing + 1] = Fields.Required[i]
        end
    end

    if #missing > 0 then
        return false, ('missing %d required field(s): %s')
            :format(#missing, table.concat(missing, ', ', 1, math.min(#missing, 5)))
    end

    entry.originals = clean
    debugPrint(('cached vanilla snapshot for %s'):format(model))
    return true, nil
end

---Models that are configured but have no vanilla snapshot yet.
---@return string[]
function Store.MissingOriginals()
    local missing = {}
    for i = 1, #Config.Vehicles do
        local model = Config.Vehicles[i].model
        local entry = Store.tunes[model]
        if not entry or not entry.originals then
            missing[#missing + 1] = model
        end
    end
    return missing
end

--------------------------------------------------------------------------------
-- Mutations
--------------------------------------------------------------------------------

---@return boolean ok, string? err
function Store.SetValue(model, fieldName, value)
    local entry, err = Store.Ensure(model)
    if not entry then return false, err end

    local sanitized, sanitizeErr = Util.SanitizeValue(fieldName, value)
    if not sanitized then return false, sanitizeErr end

    entry.values[fieldName] = sanitized
    Store.Bump()
    return true, nil
end

---@return boolean ok, string? err
function Store.ClearValue(model, fieldName)
    local entry, err = Store.Ensure(model)
    if not entry then return false, err end
    if not Fields.EditableByName[fieldName] then
        return false, ('"%s" is not an editable field'):format(tostring(fieldName))
    end

    entry.values[fieldName] = nil
    Store.Bump()
    return true, nil
end

---@return boolean ok, string? err
function Store.SetTier(model, tier)
    local entry, err = Store.Ensure(model)
    if not entry then return false, err end

    tier = math.floor(tonumber(tier) or 0)
    if tier < Config.MinTier or tier > Config.MaxTier then
        return false, ('tier must be between %d and %d'):format(Config.MinTier, Config.MaxTier)
    end

    entry.tier = tier
    Store.Bump()
    return true, nil
end

---@return boolean ok, string? err
function Store.SetMod(model, modId, level)
    local entry, err = Store.Ensure(model)
    if not entry then return false, err end

    if modId == 'turbo' then
        entry.mods.turbo = level and true or false
        Store.Bump()
        return true, nil
    end

    local modType = Config.ModTypeById[modId]
    if not modType then
        return false, ('"%s" is not a known mod type'):format(tostring(modId))
    end

    level = math.floor(tonumber(level) or -1)
    entry.mods[modId] = math.min(math.max(level, -1), modType.max)
    Store.Bump()
    return true, nil
end

---Drop a per-vehicle mod override so the tier default applies again.
function Store.ClearMod(model, modId)
    local entry, err = Store.Ensure(model)
    if not entry then return false, err end
    entry.mods[modId] = nil
    Store.Bump()
    return true, nil
end

---Roll every band the tier declares. Fields the tier has no band for keep
---whatever they currently have.
---@param model string
---@param tier number? defaults to the vehicle's current tier
---@return boolean ok, string? err
function Store.Randomize(model, tier)
    local entry, err = Store.Ensure(model)
    if not entry then return false, err end

    if tier then
        local ok, tierErr = Store.SetTier(model, tier)
        if not ok then return false, tierErr end
    end

    local tierConfig = Config.Tiers[entry.tier]
    if not tierConfig then
        return false, ('tier %s has no configuration'):format(tostring(entry.tier))
    end

    local rolled = Util.RollTier(tierConfig)
    for fieldName, value in pairs(rolled) do
        entry.values[fieldName] = value
    end

    debugPrint(('rolled %s at tier %d'):format(model, entry.tier))
    Store.Bump()
    return true, nil
end

---Roll every configured vehicle at its own tier.
---@return number count
function Store.RandomizeAll()
    local count = 0
    for i = 1, #Config.Vehicles do
        local ok = Store.Randomize(Config.Vehicles[i].model)
        if ok then count = count + 1 end
    end
    return count
end

---Drop every edit and mod override, returning the vehicle to vanilla.
function Store.Reset(model)
    local entry, err = Store.Ensure(model)
    if not entry then return false, err end

    entry.values = {}
    entry.mods = {}
    entry.tier = (Config.VehicleByModel[entry.model] or {}).tier or 1
    Store.Bump()
    return true, nil
end

--------------------------------------------------------------------------------
-- Resolution
--------------------------------------------------------------------------------

---Effective mod levels: tier defaults with per-vehicle overrides on top.
---@param model string
---@return table
function Store.ResolveMods(model)
    local entry = Store.Get(model)
    if not entry then return {} end

    local tierMods = (Config.Tiers[entry.tier] or {}).mods or {}
    local resolved = {}

    for i = 1, #Config.ModTypes do
        local modId = Config.ModTypes[i].id
        local override = entry.mods[modId]
        resolved[modId] = override ~= nil and override or (tierMods[modId] or -1)
    end

    local turboOverride = entry.mods.turbo
    resolved.turbo = turboOverride ~= nil and turboOverride or (tierMods.turbo or false)

    return resolved
end

---Full field set the client should apply: originals with edits on top.
---Returns nil while the vanilla snapshot is still missing, because applying a
---partial set would leave the live vehicle disagreeing with handling.meta.
---@param model string
---@return table?
function Store.ResolveValues(model)
    local entry = Store.Get(model)
    if not entry or not entry.originals then return nil end

    local resolved = Util.DeepCopy(entry.originals)
    for fieldName, value in pairs(entry.values) do
        resolved[fieldName] = value
    end

    return resolved
end

---Payload broadcast to clients.
---@return table
function Store.BuildSync()
    local payload = { version = Store.version, tunes = {} }

    for model, entry in pairs(Store.tunes) do
        payload.tunes[model] = {
            model = model,
            tier = entry.tier,
            values = Store.ResolveValues(model),
            edits = Util.DeepCopy(entry.values),
            originals = entry.originals and Util.DeepCopy(entry.originals) or nil,
            mods = Store.ResolveMods(model),
            overrides = Util.DeepCopy(entry.mods),
        }
    end

    -- Present only when ox_core is running; tells clients which spawned
    -- vehicles have mods that are not ours to touch.
    if OxCore and OxCore.available then
        payload.oxPolicy = OxCore.BuildPolicy()
    end

    return payload
end
