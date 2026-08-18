--[[
    Pure helpers shared by client and server.

    Nothing in here touches a native or a FiveM global, so `tests/` can require
    it directly and assert on the maths that actually matters (unit conversion,
    clamping, tier rolls).
]]

Util = {}

local RAD_TO_DEG = 180.0 / math.pi

---Clamp `value` into [min, max].
function Util.Clamp(value, min, max)
    if min and value < min then return min end
    if max and value > max then return max end
    return value
end

---Round to `decimals` places. `decimals = 0` returns an integer.
function Util.Round(value, decimals)
    local mult = 10 ^ (decimals or 0)
    local rounded = math.floor(value * mult + (value >= 0 and 0.5 or -0.5)) / mult
    if (decimals or 0) <= 0 then
        return math.tointeger(rounded) or rounded
    end
    return rounded
end

---Recursive table copy. Used so a stored tune is never aliased into a menu.
function Util.DeepCopy(source)
    if type(source) ~= 'table' then return source end
    local copy = {}
    for key, value in pairs(source) do
        copy[key] = Util.DeepCopy(value)
    end
    return copy
end

--------------------------------------------------------------------------------
-- Unit conversion (see the header of shared/fields.lua)
--------------------------------------------------------------------------------

---Convert a handling.meta value into the units the natives expect.
---@param field table entry from Fields.All / Fields.Editable
---@param metaValue number
---@return number
function Util.ToRuntime(field, metaValue)
    if field.special == 'driveBias' then
        -- The loader special-cases pure RWD / pure FWD instead of scaling.
        if metaValue <= 0.0 then return 0.0 end
        if metaValue >= 1.0 then return 1.0 end
        return metaValue * 2.0
    end
    if field.metaScale then
        return metaValue / field.metaScale
    end
    return metaValue
end

---Convert a value read off a native back into handling.meta units.
---@param field table
---@param runtimeValue number
---@param rearValue number? runtime rear bias, only used by fDriveBiasFront
---@return number
function Util.ToMeta(field, runtimeValue, rearValue)
    if field.special == 'driveBias' then
        -- front/rear together disambiguate: FWD is (1, 0), 50/50 AWD is (1, 1).
        if rearValue then
            if runtimeValue <= 0.0 then return 0.0 end
            if rearValue <= 0.0 then return 1.0 end
            return runtimeValue * 0.5
        end
        if runtimeValue <= 0.0 then return 0.0 end
        if runtimeValue >= 2.0 then return 1.0 end
        return runtimeValue * 0.5
    end
    if field.metaScale then
        return runtimeValue * field.metaScale
    end
    return runtimeValue
end

--------------------------------------------------------------------------------
-- Validation
--------------------------------------------------------------------------------

---Coerce and clamp an inbound value for an editable field.
---Returns nil plus a reason when the field is not editable or the value is not
---a finite number. The server calls this on everything a client sends.
---@param fieldName string
---@param value any
---@return number? value, string? err
function Util.SanitizeValue(fieldName, value)
    local field = Fields.EditableByName[fieldName]
    if not field then
        return nil, ('"%s" is not an editable field'):format(tostring(fieldName))
    end

    local number = tonumber(value)
    if not number then
        return nil, ('"%s" is not a number'):format(tostring(value))
    end
    -- Rejects nan (nan ~= nan) and both infinities, either of which would be
    -- written straight into handling.meta and corrupt the vehicle.
    if number ~= number or number == math.huge or number == -math.huge then
        return nil, 'value is not finite'
    end

    number = Util.Clamp(number, field.min, field.max)
    return Util.Round(number, field.decimals), nil
end

--------------------------------------------------------------------------------
-- Tier rolls
--------------------------------------------------------------------------------

---Roll a uniform random value inside an absolute tier band.
---@param band table { min = number, max = number }
---@param decimals number
---@return number
function Util.RollBand(band, decimals)
    local min, max = band.min, band.max
    if min > max then min, max = max, min end

    if (decimals or 0) <= 0 then
        return math.random(math.floor(min + 0.5), math.floor(max + 0.5))
    end

    return Util.Round(min + math.random() * (max - min), decimals)
end

---Roll a full set of values for `tier`, in handling.meta units.
---Fields the tier declares no band for are left untouched by the caller.
---@param tier table entry from Config.Tiers
---@return table<string, number>
function Util.RollTier(tier)
    local rolled = {}
    if not tier or not tier.fields then return rolled end

    for fieldName, band in pairs(tier.fields) do
        local field = Fields.EditableByName[fieldName]
        if field then
            local value = Util.RollBand(band, field.decimals)
            -- A band that runs outside the field's hard limits still gets
            -- clamped -- the field range wins over config.
            rolled[fieldName] = Util.Round(Util.Clamp(value, field.min, field.max), field.decimals)
        end
    end

    return rolled
end

--------------------------------------------------------------------------------
-- Display
--------------------------------------------------------------------------------

---Format a value for the menu, e.g. `0.3200` or `200.00 km/h`.
function Util.FormatValue(field, value)
    if value == nil then return '—' end
    local decimals = field.decimals or 3
    local text
    if decimals <= 0 then
        text = tostring(math.tointeger(Util.Round(value, 0)) or value)
    else
        text = ('%.' .. decimals .. 'f'):format(value)
    end
    if field.unit then
        text = text .. ' ' .. field.unit
    end
    return text
end

---Signed percentage difference between `current` and `original`.
---@return string
function Util.FormatDelta(original, current)
    if original == nil or current == nil then return '' end
    if math.abs(original) < 1e-9 then
        return current == original and '±0%' or 'n/a'
    end
    local percent = ((current - original) / math.abs(original)) * 100.0
    if math.abs(percent) < 0.05 then return '±0%' end
    return ('%+.1f%%'):format(percent)
end

Util.RAD_TO_DEG = RAD_TO_DEG
