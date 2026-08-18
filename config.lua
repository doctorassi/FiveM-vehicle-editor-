Config = {}

--------------------------------------------------------------------------------
-- Access
--------------------------------------------------------------------------------

-- Every action is re-checked against this ace on the server, so hiding the
-- command is not the security boundary -- this is.
--   add_ace group.admin vehicleeditor.admin allow
Config.AcePermission = 'vehicleeditor.admin'

Config.Command = 'vehedit'
Config.CommandHelp = 'Open the vehicle editor'

--------------------------------------------------------------------------------
-- Behaviour
--------------------------------------------------------------------------------

-- How often (ms) each client sweeps the vehicle pool to apply tunes to newly
-- streamed vehicles. Lower = snappier, higher = cheaper.
Config.ApplyInterval = 750

-- Apply performance mods (engine/brakes/etc.) on top of handling.
Config.ApplyMods = true

-- Write data/handling.meta whenever a tune is saved. Turning this off keeps the
-- editor working live but nothing will survive a restart.
Config.WriteMetaOnSave = true

-- Print what the editor is doing to the server console.
Config.Debug = false

--------------------------------------------------------------------------------
-- ox_core integration (optional)
--------------------------------------------------------------------------------
-- Picked up automatically when ox_core is running; everything here is ignored
-- otherwise. See the README for the exports this exposes.

Config.OxCore = {
    -- true / false to force, 'auto' to use ox_core when it is started.
    Enabled = 'auto',

    -- Apply the tune the moment ox:spawnedVehicle fires, instead of waiting for
    -- the next pool sweep. Costs nothing and removes the visible settling.
    ApplyOnSpawn = true,

    -- Owned and group vehicles carry performance mods a player paid for, and
    -- ox_core persists them in the database.
    --   false -> leave those mods alone; handling is still tuned to the tier.
    --   true  -> overwrite them with the tier's mods on every spawn.
    -- Leave this false unless tiers are meant to override player upgrades.
    ApplyModsToOwned = false,

    -- When the tier's mods ARE applied to an ox_core vehicle, also write them
    -- into its saved properties so garages and respawns keep them, instead of
    -- forcing them client-side every time.
    PersistModsToProperties = true,
}

--------------------------------------------------------------------------------
-- Vehicles you want to edit
--------------------------------------------------------------------------------
-- `model` is the spawn name. `tier` is the starting tier (1-5) used by the
-- automatic generator and as the default source of performance mods.
--
-- Optional: `handling = 'SOMETHING'` overrides the handling id written to
-- handling.meta. It defaults to the uppercased spawn name, which is correct for
-- the overwhelming majority of vehicles -- set it only for a model whose
-- handlingName differs from its model name.

Config.Vehicles = {
    { model = 'blista',  label = 'Dinka Blista',    tier = 1 },
    { model = 'futo',    label = 'Karin Futo',      tier = 2 },
    { model = 'sultan',  label = 'Karin Sultan',    tier = 3 },
    { model = 'kuruma',  label = 'Karin Kuruma',    tier = 3 },
    { model = 'banshee', label = 'Bravado Banshee', tier = 4 },
    { model = 'adder',   label = 'Truffade Adder',  tier = 5 },
}

--------------------------------------------------------------------------------
-- Performance mods
--------------------------------------------------------------------------------
-- Mod type ids used by SetVehicleMod. Level -1 is stock; the maximum level
-- varies per vehicle, so anything too high is clamped to what the model has.

Config.ModTypes = {
    { id = 'engine',       modType = 11, label = 'Engine',       max = 3 },
    { id = 'brakes',       modType = 12, label = 'Brakes',       max = 2 },
    { id = 'transmission', modType = 13, label = 'Transmission', max = 2 },
    { id = 'suspension',   modType = 15, label = 'Suspension',   max = 3 },
    { id = 'armour',       modType = 16, label = 'Armour',       max = 4 },
}

-- Turbo is a toggle (mod type 18) rather than a level.
Config.TurboModType = 18

--------------------------------------------------------------------------------
-- Tiers
--------------------------------------------------------------------------------
-- `fields` are ABSOLUTE min/max bands in handling.meta units. The automatic
-- generator rolls a uniform random value inside the band, so every car of a
-- given tier lands in the same performance window regardless of what it was in
-- vanilla. A field with no band here is left at its original value when rolling.
--
-- `mods` are the tier's default performance mod levels. A per-vehicle override
-- set in the menu wins over these.

Config.Tiers = {
    [1] = {
        label = 'Tier 1 — Stock',
        icon = 'circle-1',
        colour = '#9ca3af',
        mods = { engine = -1, brakes = -1, transmission = -1, suspension = -1, armour = -1, turbo = false },
        fields = {
            fInitialDriveForce              = { min = 0.20,  max = 0.26 },
            fInitialDriveMaxFlatVel         = { min = 125.0, max = 148.0 },
            fDriveInertia                   = { min = 0.85,  max = 1.00 },
            nInitialDriveGears              = { min = 5,     max = 5 },
            fClutchChangeRateScaleUpShift   = { min = 2.0,   max = 3.0 },
            fClutchChangeRateScaleDownShift = { min = 2.0,   max = 3.0 },
            fBrakeForce                     = { min = 0.60,  max = 0.82 },
            fHandBrakeForce                 = { min = 0.60,  max = 0.80 },
            fTractionCurveMax               = { min = 1.95,  max = 2.20 },
            fTractionCurveMin               = { min = 1.75,  max = 1.95 },
            fTractionCurveLateral           = { min = 21.0,  max = 23.0 },
            fLowSpeedTractionLossMult       = { min = 1.00,  max = 1.30 },
            fTractionLossMult               = { min = 1.00,  max = 1.15 },
            fSuspensionForce                = { min = 1.80,  max = 2.30 },
            fAntiRollBarForce               = { min = 0.30,  max = 0.55 },
        },
    },

    [2] = {
        label = 'Tier 2 — Street',
        icon = 'circle-2',
        colour = '#4ade80',
        mods = { engine = 1, brakes = 1, transmission = 0, suspension = 1, armour = -1, turbo = false },
        fields = {
            fInitialDriveForce              = { min = 0.26,  max = 0.31 },
            fInitialDriveMaxFlatVel         = { min = 148.0, max = 165.0 },
            fDriveInertia                   = { min = 1.00,  max = 1.10 },
            nInitialDriveGears              = { min = 5,     max = 6 },
            fClutchChangeRateScaleUpShift   = { min = 2.5,   max = 3.5 },
            fClutchChangeRateScaleDownShift = { min = 2.5,   max = 3.5 },
            fBrakeForce                     = { min = 0.82,  max = 1.00 },
            fHandBrakeForce                 = { min = 0.70,  max = 0.90 },
            fTractionCurveMax               = { min = 2.20,  max = 2.40 },
            fTractionCurveMin               = { min = 1.95,  max = 2.15 },
            fTractionCurveLateral           = { min = 21.5,  max = 23.5 },
            fLowSpeedTractionLossMult       = { min = 0.95,  max = 1.20 },
            fTractionLossMult               = { min = 0.95,  max = 1.10 },
            fSuspensionForce                = { min = 2.20,  max = 2.70 },
            fAntiRollBarForce               = { min = 0.45,  max = 0.70 },
        },
    },

    [3] = {
        label = 'Tier 3 — Sport',
        icon = 'circle-3',
        colour = '#38bdf8',
        mods = { engine = 2, brakes = 1, transmission = 1, suspension = 2, armour = -1, turbo = false },
        fields = {
            fInitialDriveForce              = { min = 0.31,  max = 0.36 },
            fInitialDriveMaxFlatVel         = { min = 165.0, max = 180.0 },
            fDriveInertia                   = { min = 1.05,  max = 1.20 },
            nInitialDriveGears              = { min = 6,     max = 6 },
            fClutchChangeRateScaleUpShift   = { min = 3.0,   max = 4.5 },
            fClutchChangeRateScaleDownShift = { min = 3.0,   max = 4.5 },
            fBrakeForce                     = { min = 1.00,  max = 1.15 },
            fHandBrakeForce                 = { min = 0.80,  max = 1.00 },
            fTractionCurveMax               = { min = 2.40,  max = 2.60 },
            fTractionCurveMin               = { min = 2.10,  max = 2.30 },
            fTractionCurveLateral           = { min = 22.0,  max = 24.0 },
            fLowSpeedTractionLossMult       = { min = 0.85,  max = 1.10 },
            fTractionLossMult               = { min = 0.90,  max = 1.05 },
            fSuspensionForce                = { min = 2.60,  max = 3.10 },
            fAntiRollBarForce               = { min = 0.60,  max = 0.85 },
        },
    },

    [4] = {
        label = 'Tier 4 — Super',
        icon = 'circle-4',
        colour = '#a78bfa',
        mods = { engine = 3, brakes = 2, transmission = 2, suspension = 3, armour = -1, turbo = true },
        fields = {
            fInitialDriveForce              = { min = 0.36,  max = 0.42 },
            fInitialDriveMaxFlatVel         = { min = 180.0, max = 196.0 },
            fDriveInertia                   = { min = 1.15,  max = 1.30 },
            nInitialDriveGears              = { min = 6,     max = 7 },
            fClutchChangeRateScaleUpShift   = { min = 4.0,   max = 6.0 },
            fClutchChangeRateScaleDownShift = { min = 4.0,   max = 6.0 },
            fBrakeForce                     = { min = 1.15,  max = 1.32 },
            fHandBrakeForce                 = { min = 0.90,  max = 1.10 },
            fTractionCurveMax               = { min = 2.60,  max = 2.85 },
            fTractionCurveMin               = { min = 2.25,  max = 2.50 },
            fTractionCurveLateral           = { min = 22.5,  max = 24.5 },
            fLowSpeedTractionLossMult       = { min = 0.75,  max = 1.00 },
            fTractionLossMult               = { min = 0.85,  max = 1.00 },
            fSuspensionForce                = { min = 3.00,  max = 3.60 },
            fAntiRollBarForce               = { min = 0.75,  max = 1.00 },
        },
    },

    [5] = {
        label = 'Tier 5 — Hyper',
        icon = 'circle-5',
        colour = '#f97316',
        mods = { engine = 3, brakes = 2, transmission = 2, suspension = 3, armour = -1, turbo = true },
        fields = {
            fInitialDriveForce              = { min = 0.42,  max = 0.50 },
            fInitialDriveMaxFlatVel         = { min = 196.0, max = 215.0 },
            fDriveInertia                   = { min = 1.25,  max = 1.45 },
            nInitialDriveGears              = { min = 7,     max = 8 },
            fClutchChangeRateScaleUpShift   = { min = 5.0,   max = 8.0 },
            fClutchChangeRateScaleDownShift = { min = 5.0,   max = 8.0 },
            fBrakeForce                     = { min = 1.32,  max = 1.55 },
            fHandBrakeForce                 = { min = 1.00,  max = 1.25 },
            fTractionCurveMax               = { min = 2.85,  max = 3.15 },
            fTractionCurveMin               = { min = 2.45,  max = 2.75 },
            fTractionCurveLateral           = { min = 23.0,  max = 25.0 },
            fLowSpeedTractionLossMult       = { min = 0.60,  max = 0.90 },
            fTractionLossMult               = { min = 0.80,  max = 0.95 },
            fSuspensionForce                = { min = 3.40,  max = 4.10 },
            fAntiRollBarForce               = { min = 0.90,  max = 1.20 },
        },
    },
}

Config.MinTier = 1
Config.MaxTier = 5

--------------------------------------------------------------------------------
-- Derived lookups (do not edit)
--------------------------------------------------------------------------------

Config.VehicleByModel = {}
for i = 1, #Config.Vehicles do
    local vehicle = Config.Vehicles[i]
    vehicle.model = vehicle.model:lower()
    vehicle.tier = math.min(math.max(vehicle.tier or 1, Config.MinTier), Config.MaxTier)
    vehicle.label = vehicle.label or vehicle.model
    Config.VehicleByModel[vehicle.model] = vehicle
end

Config.ModTypeById = {}
for i = 1, #Config.ModTypes do
    Config.ModTypeById[Config.ModTypes[i].id] = Config.ModTypes[i]
end
