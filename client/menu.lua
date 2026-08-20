--[[
    ox_lib menus.

    Every option here is a view over server state; nothing is applied locally
    from the menu. A selection fires a callback, the server validates it, and the
    resulting sync is what actually changes the vehicle.
]]

local Menu = {
    ---Latest server state: { canEdit, missing, sync }
    state = nil,
}

--------------------------------------------------------------------------------
-- State helpers
--------------------------------------------------------------------------------

---@return boolean ok
local function refresh()
    local state = lib.callback.await('vehicleeditor:getState', false)
    if not state then
        lib.notify({ title = 'Vehicle Editor', description = 'No response from the server.', type = 'error' })
        return false
    end

    Menu.state = state
    return true
end

---@param model string
---@return table?
local function tuneFor(model)
    local sync = Menu.state and Menu.state.sync
    return sync and sync.tunes and sync.tunes[model] or nil
end

---Run a mutation callback, report the result and refresh state.
---@param name string
---@param ... any
---@return boolean ok, any extra
local function call(name, ...)
    local ok, err, extra = lib.callback.await('vehicleeditor:' .. name, false, ...)

    if not ok then
        lib.notify({
            title = 'Vehicle Editor',
            description = err or 'That action was rejected.',
            type = 'error',
        })
        return false, nil
    end

    refresh()
    return true, extra
end

---Tier band for a field, if the vehicle's tier declares one.
---@return table? band
local function bandFor(tier, fieldName)
    local tierConfig = Config.Tiers[tier]
    return tierConfig and tierConfig.fields and tierConfig.fields[fieldName] or nil
end

local function tierLabel(tier)
    local tierConfig = Config.Tiers[tier]
    return tierConfig and tierConfig.label or ('Tier ' .. tostring(tier))
end

local function tierColour(tier)
    local tierConfig = Config.Tiers[tier]
    return tierConfig and tierConfig.colour or '#ffffff'
end

---How many fields deviate from vanilla.
local function editCount(tune)
    if not tune or not tune.edits then return 0 end
    local count = 0
    for _ in pairs(tune.edits) do count = count + 1 end
    return count
end

--------------------------------------------------------------------------------
-- Vanilla capture
--------------------------------------------------------------------------------

---Capture any missing vanilla snapshots. Without these the editor has nothing to
---compare against and cannot write a complete handling.meta entry, so this runs
---automatically the first time the menu is opened.
---@return boolean ok
local function ensureOriginals()
    local missing = Menu.state and Menu.state.missing
    if not missing or #missing == 0 then return true end

    lib.notify({
        title = 'Vehicle Editor',
        description = ('Capturing vanilla values for %d vehicle(s)…'):format(#missing),
        type = 'inform',
    })

    local captured, failures = Originals.CaptureAndSubmit(missing)

    if #failures > 0 then
        lib.notify({
            title = 'Vehicle Editor',
            description = ('Could not capture: %s'):format(table.concat(failures, ', ')),
            type = 'error',
            duration = 8000,
        })
    end

    if captured > 0 then
        lib.notify({
            title = 'Vehicle Editor',
            description = ('Captured vanilla values for %d vehicle(s).'):format(captured),
            type = 'success',
        })
    end

    return refresh()
end

--------------------------------------------------------------------------------
-- Field editing
--------------------------------------------------------------------------------

local function editField(model, field)
    local tune = tuneFor(model)
    if not tune then return end

    local original = tune.originals and tune.originals[field.name] or nil
    local current = tune.values and tune.values[field.name] or original
    local band = bandFor(tune.tier, field.name)
    local isEdited = tune.edits and tune.edits[field.name] ~= nil

    local decimals = field.decimals or 3
    local rows = {
        {
            type = 'number',
            label = field.label .. (field.unit and (' (' .. field.unit .. ')') or ''),
            description = ('Vanilla: %s%s'):format(
                Util.FormatValue(field, original),
                band and ('   •   Tier band: %s – %s'):format(
                    Util.FormatValue(field, band.min), Util.FormatValue(field, band.max)) or ''),
            default = current,
            min = field.min,
            max = field.max,
            step = decimals > 0 and (10 ^ -decimals) or 1,
            required = true,
        },
    }

    if isEdited then
        rows[#rows + 1] = {
            type = 'checkbox',
            label = 'Restore the vanilla value',
            checked = false,
        }
    end

    local input = lib.inputDialog(('%s — %s'):format(tune.model:upper(), field.label), rows)
    if not input then return end

    if isEdited and input[2] then
        call('clearValue', model, field.name)
    elseif input[1] ~= nil then
        call('setValue', model, field.name, input[1])
    end
end

--------------------------------------------------------------------------------
-- Contexts
--------------------------------------------------------------------------------

local function categoryContextId(model, category)
    return ('vehedit_cat_%s_%s'):format(model, category)
end

local function vehicleContextId(model)
    return 'vehedit_vehicle_' .. model
end

---One category of handling fields, showing vanilla vs current for each.
local function showCategory(model, category)
    local tune = tuneFor(model)
    if not tune then return end

    local options = {}

    for _, field in ipairs(Fields.ByCategory[category.id]) do
        local original = tune.originals and tune.originals[field.name] or nil
        local current = tune.values and tune.values[field.name] or original
        local isEdited = tune.edits and tune.edits[field.name] ~= nil
        local band = bandFor(tune.tier, field.name)

        local metadata = {
            { label = 'Original', value = Util.FormatValue(field, original) },
            { label = 'Current',  value = Util.FormatValue(field, current) },
            { label = 'Change',   value = Util.FormatDelta(original, current) },
        }

        if band then
            metadata[#metadata + 1] = {
                label = 'Tier ' .. tostring(tune.tier) .. ' band',
                value = ('%s – %s'):format(Util.FormatValue(field, band.min), Util.FormatValue(field, band.max)),
            }
        end

        options[#options + 1] = {
            title = field.label,
            description = ('%s  →  %s   %s'):format(
                Util.FormatValue(field, original),
                Util.FormatValue(field, current),
                isEdited and Util.FormatDelta(original, current) or '(vanilla)'),
            icon = isEdited and 'pen-to-square' or 'equals',
            iconColor = isEdited and tierColour(tune.tier) or nil,
            metadata = metadata,
            onSelect = function()
                editField(model, field)
                showCategory(model, category)
            end,
        }
    end

    lib.registerContext({
        id = categoryContextId(model, category.id),
        title = ('%s — %s'):format(tune.model:upper(), category.label),
        menu = vehicleContextId(model),
        options = options,
    })

    lib.showContext(categoryContextId(model, category.id))
end

---Performance mods for one vehicle: tier default with optional override.
local function showMods(model)
    local tune = tuneFor(model)
    if not tune then return end

    local tierMods = (Config.Tiers[tune.tier] or {}).mods or {}
    local options = {}

    local function levelLabel(level)
        if level == nil or level < 0 then return 'Stock' end
        return 'Level ' .. tostring(level + 1)
    end

    for i = 1, #Config.ModTypes do
        local modType = Config.ModTypes[i]
        local effective = tune.mods and tune.mods[modType.id] or -1
        local override = tune.overrides and tune.overrides[modType.id]

        options[#options + 1] = {
            title = modType.label,
            description = ('%s   %s'):format(
                levelLabel(effective),
                override ~= nil and '(override)' or ('(tier default: %s)'):format(levelLabel(tierMods[modType.id]))),
            icon = override ~= nil and 'wrench' or 'layer-group',
            iconColor = override ~= nil and tierColour(tune.tier) or nil,
            onSelect = function()
                local choices = { { value = 'default', label = ('Use tier default (%s)'):format(levelLabel(tierMods[modType.id])) } }
                choices[#choices + 1] = { value = '-1', label = 'Stock' }
                for level = 0, modType.max do
                    choices[#choices + 1] = { value = tostring(level), label = levelLabel(level) }
                end

                local input = lib.inputDialog(('%s — %s'):format(tune.model:upper(), modType.label), {
                    {
                        type = 'select',
                        label = 'Level',
                        options = choices,
                        default = override ~= nil and tostring(override) or 'default',
                        required = true,
                    },
                })
                if not input then return end

                if input[1] == 'default' then
                    call('clearMod', model, modType.id)
                else
                    call('setMod', model, modType.id, tonumber(input[1]))
                end

                showMods(model)
            end,
        }
    end

    local turboEffective = tune.mods and tune.mods.turbo or false
    local turboOverride = tune.overrides and tune.overrides.turbo

    options[#options + 1] = {
        title = 'Turbo',
        description = ('%s   %s'):format(
            turboEffective and 'Fitted' or 'Not fitted',
            turboOverride ~= nil and '(override)' or ('(tier default: %s)'):format(tierMods.turbo and 'fitted' or 'not fitted')),
        icon = turboOverride ~= nil and 'wrench' or 'layer-group',
        iconColor = turboOverride ~= nil and tierColour(tune.tier) or nil,
        onSelect = function()
            local input = lib.inputDialog(('%s — Turbo'):format(tune.model:upper()), {
                {
                    type = 'select',
                    label = 'Turbo',
                    options = {
                        { value = 'default', label = ('Use tier default (%s)'):format(tierMods.turbo and 'fitted' or 'not fitted') },
                        { value = 'on',      label = 'Fitted' },
                        { value = 'off',     label = 'Not fitted' },
                    },
                    default = turboOverride == nil and 'default' or (turboOverride and 'on' or 'off'),
                    required = true,
                },
            })
            if not input then return end

            if input[1] == 'default' then
                call('clearMod', model, 'turbo')
            else
                call('setMod', model, 'turbo', input[1] == 'on')
            end

            showMods(model)
        end,
    }

    lib.registerContext({
        id = 'vehedit_mods_' .. model,
        title = ('%s — Performance Mods'):format(tune.model:upper()),
        menu = vehicleContextId(model),
        options = options,
    })

    lib.showContext('vehedit_mods_' .. model)
end

local showVehicle

---Ask for a tier and roll this one vehicle from its band.
local function randomizeVehicle(model)
    local tune = tuneFor(model)
    if not tune then return end

    local tierOptions = {}
    for tier = Config.MinTier, Config.MaxTier do
        tierOptions[#tierOptions + 1] = { value = tostring(tier), label = tierLabel(tier) }
    end

    local input = lib.inputDialog(('Randomize %s'):format(tune.model:upper()), {
        {
            type = 'select',
            label = 'Tier',
            description = 'Values are rolled at random inside this tier\'s absolute band.',
            options = tierOptions,
            default = tostring(tune.tier),
            required = true,
        },
    })
    if not input then return end

    local ok = call('randomize', model, tonumber(input[1]))
    if ok then
        lib.notify({
            title = 'Vehicle Editor',
            description = ('%s rolled at %s.'):format(model:upper(), tierLabel(tonumber(input[1]))),
            type = 'success',
        })
    end

    showVehicle(model)
end

---Per-vehicle menu.
function showVehicle(model)
    local tune = tuneFor(model)
    if not tune then
        lib.notify({ title = 'Vehicle Editor', description = 'That vehicle is not configured.', type = 'error' })
        return
    end

    local configured = Config.VehicleByModel[model] or {}
    local edits = editCount(tune)
    local options = {}

    options[#options + 1] = {
        title = 'Tier',
        description = tierLabel(tune.tier),
        icon = (Config.Tiers[tune.tier] or {}).icon or 'layer-group',
        iconColor = tierColour(tune.tier),
        onSelect = function()
            local tierOptions = {}
            for tier = Config.MinTier, Config.MaxTier do
                tierOptions[#tierOptions + 1] = { value = tostring(tier), label = tierLabel(tier) }
            end

            local input = lib.inputDialog(('%s — Tier'):format(tune.model:upper()), {
                {
                    type = 'select',
                    label = 'Tier',
                    description = 'Sets the tier band and the default performance mods. Existing handling values are left alone until you randomize.',
                    options = tierOptions,
                    default = tostring(tune.tier),
                    required = true,
                },
            })
            if not input then return end

            call('setTier', model, tonumber(input[1]))
            showVehicle(model)
        end,
    }

    options[#options + 1] = {
        title = 'Randomize this vehicle',
        description = 'Roll new values from a tier band',
        icon = 'dice',
        onSelect = function() randomizeVehicle(model) end,
    }

    options[#options + 1] = {
        title = 'Performance mods',
        description = 'Engine, brakes, transmission, suspension, turbo',
        icon = 'screwdriver-wrench',
        arrow = true,
        onSelect = function() showMods(model) end,
    }

    for i = 1, #Fields.Categories do
        local category = Fields.Categories[i]
        local changed = 0
        for _, field in ipairs(Fields.ByCategory[category.id]) do
            if tune.edits and tune.edits[field.name] ~= nil then changed = changed + 1 end
        end

        options[#options + 1] = {
            title = category.label,
            description = changed > 0
                and ('%d of %d field(s) changed'):format(changed, #Fields.ByCategory[category.id])
                or ('%d field(s), all vanilla'):format(#Fields.ByCategory[category.id]),
            icon = category.icon,
            iconColor = changed > 0 and tierColour(tune.tier) or nil,
            arrow = true,
            onSelect = function() showCategory(model, category) end,
        }
    end

    options[#options + 1] = {
        title = 'Reset to vanilla',
        description = 'Drop every edit and mod override for this vehicle',
        icon = 'rotate-left',
        iconColor = '#f87171',
        onSelect = function()
            local confirm = lib.alertDialog({
                header = 'Reset ' .. model:upper(),
                content = 'This removes every handling edit and mod override for this vehicle and puts it back to its vanilla values. Continue?',
                centered = true,
                cancel = true,
            })
            if confirm ~= 'confirm' then return showVehicle(model) end

            call('reset', model)
            showVehicle(model)
        end,
    }

    lib.registerContext({
        id = vehicleContextId(model),
        title = configured.label or model:upper(),
        menu = 'vehedit_list',
        options = options,
        metadata = {
            { label = 'Model', value = model },
            { label = 'Tier', value = tierLabel(tune.tier) },
            { label = 'Edited fields', value = tostring(edits) },
            { label = 'Vanilla captured', value = tune.originals and 'yes' or 'no' },
        },
    })

    lib.showContext(vehicleContextId(model))
end

---All configured vehicles.
local function showList()
    local options = {}

    for i = 1, #Config.Vehicles do
        local configured = Config.Vehicles[i]
        local tune = tuneFor(configured.model)
        local edits = editCount(tune)

        options[#options + 1] = {
            title = configured.label,
            description = ('%s   •   %s   •   %s'):format(
                configured.model,
                tune and tierLabel(tune.tier) or tierLabel(configured.tier),
                edits > 0 and (edits .. ' field(s) changed') or 'vanilla'),
            icon = (Config.Tiers[tune and tune.tier or configured.tier] or {}).icon or 'car',
            iconColor = tierColour(tune and tune.tier or configured.tier),
            arrow = true,
            onSelect = function() showVehicle(configured.model) end,
        }
    end

    lib.registerContext({
        id = 'vehedit_list',
        title = 'Vehicles',
        menu = 'vehedit_main',
        options = options,
    })

    lib.showContext('vehedit_list')
end

---The vehicle the player is sitting in, or the nearest one, if it is configured.
---@return string?
local function nearbyConfiguredModel()
    local ped = PlayerPedId()
    local vehicle = GetVehiclePedIsIn(ped, false)

    if vehicle == 0 then
        local coords = GetEntityCoords(ped)
        vehicle = GetClosestVehicle(coords.x, coords.y, coords.z, 8.0, 0, 71)
    end

    if not vehicle or vehicle == 0 or not DoesEntityExist(vehicle) then return nil end

    local hash = GetEntityModel(vehicle)
    for i = 1, #Config.Vehicles do
        if joaat(Config.Vehicles[i].model) == hash then
            return Config.Vehicles[i].model
        end
    end

    return nil
end

local function showMain()
    local options = {}
    local nearby = nearbyConfiguredModel()

    if nearby then
        local configured = Config.VehicleByModel[nearby]
        options[#options + 1] = {
            title = 'Edit ' .. (configured and configured.label or nearby:upper()),
            description = 'The vehicle you are in or standing next to',
            icon = 'car-side',
            iconColor = tierColour((tuneFor(nearby) or configured or {}).tier),
            arrow = true,
            onSelect = function() showVehicle(nearby) end,
        }
    end

    options[#options + 1] = {
        title = 'Vehicles',
        description = ('%d vehicle(s) configured'):format(#Config.Vehicles),
        icon = 'list',
        arrow = true,
        onSelect = showList,
    }

    options[#options + 1] = {
        title = 'Auto-generate every vehicle',
        description = 'Roll random values for all configured vehicles at their own tier',
        icon = 'wand-magic-sparkles',
        onSelect = function()
            local confirm = lib.alertDialog({
                header = 'Auto-generate all vehicles',
                content = ('This rolls new random handling values for all %d configured vehicle(s), each inside its own tier band. Existing edits will be overwritten. Continue?')
                    :format(#Config.Vehicles),
                centered = true,
                cancel = true,
            })
            if confirm ~= 'confirm' then return showMain() end

            local ok, count = call('randomizeAll')
            if ok then
                lib.notify({
                    title = 'Vehicle Editor',
                    description = ('Rolled %d vehicle(s).'):format(count or 0),
                    type = 'success',
                })
            end

            showMain()
        end,
    }

    options[#options + 1] = {
        title = 'Save now',
        description = 'Edits autosave; this forces an immediate write',
        icon = 'floppy-disk',
        onSelect = function()
            local ok = call('save')
            if ok then
                lib.notify({
                    title = 'Vehicle Editor',
                    description = 'Saved.',
                    type = 'success',
                })
            end
            showMain()
        end,
    }

    options[#options + 1] = {
        title = 'Reload from disk',
        description = 'Discard in-memory state and re-read the saved tunes',
        icon = 'rotate',
        onSelect = function()
            local confirm = lib.alertDialog({
                header = 'Reload from file',
                content = 'Unsaved in-memory changes are discarded and the saved tunes are re-read from disk. Continue?',
                centered = true,
                cancel = true,
            })
            if confirm ~= 'confirm' then return showMain() end

            local ok, loaded = call('reload')
            if ok then
                lib.notify({
                    title = 'Vehicle Editor',
                    description = ('Reloaded %d tune(s).'):format(loaded or 0),
                    type = 'inform',
                })
            end
            showMain()
        end,
    }

    local missing = Menu.state and Menu.state.missing or {}
    lib.registerContext({
        id = 'vehedit_main',
        title = 'Vehicle Editor',
        options = options,
        metadata = #missing > 0 and {
            { label = 'Awaiting vanilla capture', value = tostring(#missing) },
        } or nil,
    })

    lib.showContext('vehedit_main')
end

--------------------------------------------------------------------------------
-- Entry point
--------------------------------------------------------------------------------

RegisterCommand(Config.Command, function()
    if not refresh() then return end

    if not Menu.state.canEdit then
        return lib.notify({
            title = 'Vehicle Editor',
            description = 'You do not have permission to use the vehicle editor.',
            type = 'error',
        })
    end

    if not ensureOriginals() then return end

    showMain()
end, false)

TriggerEvent('chat:addSuggestion', '/' .. Config.Command, Config.CommandHelp)

---An autosave failed. Anyone who can edit needs to know immediately, because
---the edits are still in memory and will be lost on restart.
RegisterNetEvent('vehicleeditor:saveFailed', function(err)
    if not Menu.state or not Menu.state.canEdit then return end

    lib.notify({
        title = 'Vehicle Editor',
        description = ('Could not save handling.meta — edits will be lost on restart.\n%s\nRun vehedit_diag in the server console.')
            :format(err or 'unknown error'),
        type = 'error',
        duration = 12000,
    })
end)
