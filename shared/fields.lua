--[[
    Handling field catalogue.

    UNITS -- read this before touching anything in here.

    The game stores some handling values differently to how they are written in
    handling.meta. `handling.meta` is the format every FiveM developer already
    knows (fSteeringLock in degrees, fInitialDriveMaxFlatVel in km/h, ...), so
    that is the canonical unit this resource stores, displays and configures in.

    Conversion happens at exactly one boundary -- the natives:

        runtime_value = meta_value / metaScale
        meta_value    = runtime_value * metaScale

    Fields with no `metaScale` are 1:1. `fDriveBiasFront` cannot be expressed as
    a scale because the loader special-cases pure FWD/RWD, so it carries
    `special = 'driveBias'` and is handled by Util.ToMeta / Util.ToRuntime.
]]

Fields = {}

local RAD_TO_DEG = 180.0 / math.pi

---Complete CHandlingData schema, in the order it is written to handling.meta.
---Every entry here is snapshotted from vanilla and written back out, because a
---partial <Item type="CHandlingData"> makes the game default every field the
---entry omits.
---
---`optional = true` marks the handful of fields that are not physics: if the
---handling natives on a given build will not read them back, they are left out
---of the entry and the game uses its own default, which is harmless for a seat
---offset or a price tag. Every other field is required -- a vehicle that cannot
---produce one is reported and skipped rather than written incomplete.
Fields.All = {
    { name = 'fMass',                            type = 'float' },
    { name = 'fInitialDragCoeff',                type = 'float',  metaScale = 10000.0 },
    { name = 'fPercentSubmerged',                type = 'float' },
    { name = 'vecCentreOfMassOffset',            type = 'vector' },
    { name = 'vecInertiaMultiplier',             type = 'vector' },
    { name = 'fDriveBiasFront',                  type = 'float',  special = 'driveBias' },
    { name = 'nInitialDriveGears',               type = 'int' },
    { name = 'fInitialDriveForce',               type = 'float' },
    { name = 'fDriveInertia',                    type = 'float' },
    { name = 'fClutchChangeRateScaleUpShift',    type = 'float' },
    { name = 'fClutchChangeRateScaleDownShift',  type = 'float' },
    { name = 'fInitialDriveMaxFlatVel',          type = 'float',  metaScale = 3.6 },
    { name = 'fBrakeForce',                      type = 'float' },
    { name = 'fBrakeBiasFront',                  type = 'float',  metaScale = 0.5 },
    { name = 'fHandBrakeForce',                  type = 'float' },
    { name = 'fSteeringLock',                    type = 'float',  metaScale = RAD_TO_DEG },
    { name = 'fTractionCurveMax',                type = 'float' },
    { name = 'fTractionCurveMin',                type = 'float' },
    { name = 'fTractionCurveLateral',            type = 'float',  metaScale = RAD_TO_DEG },
    { name = 'fTractionSpringDeltaMax',          type = 'float' },
    { name = 'fLowSpeedTractionLossMult',        type = 'float' },
    { name = 'fCamberStiffnesss',                type = 'float' },
    { name = 'fTractionBiasFront',               type = 'float',  metaScale = 0.5 },
    { name = 'fTractionLossMult',                type = 'float' },
    { name = 'fSuspensionReboundDamp',           type = 'float' },
    { name = 'fSuspensionCompDamp',              type = 'float' },
    { name = 'fSuspensionForce',                 type = 'float' },
    { name = 'fSuspensionRaise',                 type = 'float' },
    { name = 'fSuspensionUpperLimit',            type = 'float' },
    { name = 'fSuspensionLowerLimit',            type = 'float' },
    { name = 'fSuspensionBiasFront',             type = 'float',  metaScale = 0.5 },
    { name = 'fAntiRollBarForce',                type = 'float' },
    { name = 'fAntiRollBarBiasFront',            type = 'float',  metaScale = 0.5 },
    { name = 'fRollCentreHeightFront',           type = 'float' },
    { name = 'fRollCentreHeightRear',            type = 'float' },
    { name = 'fCollisionDamageMult',             type = 'float' },
    { name = 'fWeaponDamageMult',                type = 'float' },
    { name = 'fDeformationDamageMult',           type = 'float' },
    { name = 'fEngineDamageMult',                type = 'float' },
    { name = 'fPetrolTankVolume',                type = 'float' },
    { name = 'fOilVolume',                       type = 'float' },
    { name = 'fSeatOffsetDistX',                 type = 'float',  optional = true },
    { name = 'fSeatOffsetDistY',                 type = 'float',  optional = true },
    { name = 'fSeatOffsetDistZ',                 type = 'float',  optional = true },
    { name = 'nMonetaryValue',                   type = 'int',    optional = true },
    { name = 'strModelFlags',                    type = 'flags' },
    { name = 'strHandlingFlags',                 type = 'flags' },
    { name = 'strDamageFlags',                   type = 'flags' },
}

---Lookup by field name, built once at load.
Fields.ByName = {}
for i = 1, #Fields.All do
    local field = Fields.All[i]
    field.index = i
    Fields.ByName[field.name] = field
end

---Field names that must be present in a snapshot for it to be usable.
Fields.Required = {}
for i = 1, #Fields.All do
    local field = Fields.All[i]
    if not field.optional then
        Fields.Required[#Fields.Required + 1] = field.name
    end
end

---Menu categories, in display order.
Fields.Categories = {
    { id = 'engine',       label = 'Engine',        icon = 'gauge-high' },
    { id = 'transmission', label = 'Transmission',  icon = 'gears' },
    { id = 'brakes',       label = 'Brakes',        icon = 'circle-stop' },
    { id = 'traction',     label = 'Traction',      icon = 'road' },
    { id = 'suspension',   label = 'Suspension',    icon = 'arrows-up-down' },
    { id = 'chassis',      label = 'Chassis',       icon = 'car-burst' },
}

---The subset exposed in the menu. `min`/`max` are in meta units and are the
---authoritative clamp -- the server re-applies them to every inbound value, so
---this table is a security boundary as well as a UI hint.
Fields.Editable = {
    -- Engine ---------------------------------------------------------------
    { name = 'fInitialDriveForce',      label = 'Drive Force',        category = 'engine',       min = 0.01,  max = 3.0,     decimals = 4 },
    { name = 'fInitialDriveMaxFlatVel', label = 'Top Speed',          category = 'engine',       min = 20.0,  max = 500.0,   decimals = 2, unit = 'km/h' },
    { name = 'fDriveInertia',           label = 'Drive Inertia',      category = 'engine',       min = 0.01,  max = 2.0,     decimals = 3 },
    { name = 'fInitialDragCoeff',       label = 'Drag Coefficient',   category = 'engine',       min = 0.0,   max = 200.0,   decimals = 3 },
    { name = 'fPetrolTankVolume',       label = 'Petrol Tank Volume', category = 'engine',       min = 0.0,   max = 200.0,   decimals = 2 },
    { name = 'fOilVolume',              label = 'Oil Volume',         category = 'engine',       min = 0.0,   max = 200.0,   decimals = 2 },

    -- Transmission ---------------------------------------------------------
    { name = 'nInitialDriveGears',              label = 'Gears',              category = 'transmission', min = 1,     max = 10,    decimals = 0 },
    { name = 'fClutchChangeRateScaleUpShift',   label = 'Upshift Rate',       category = 'transmission', min = 0.01,  max = 20.0,  decimals = 3 },
    { name = 'fClutchChangeRateScaleDownShift', label = 'Downshift Rate',     category = 'transmission', min = 0.01,  max = 20.0,  decimals = 3 },
    { name = 'fDriveBiasFront',                 label = 'Drive Bias (Front)', category = 'transmission', min = 0.0,   max = 1.0,   decimals = 3 },

    -- Brakes ---------------------------------------------------------------
    { name = 'fBrakeForce',     label = 'Brake Force',       category = 'brakes', min = 0.01, max = 5.0, decimals = 3 },
    { name = 'fBrakeBiasFront', label = 'Brake Bias (Front)',category = 'brakes', min = 0.0,  max = 1.0, decimals = 3 },
    { name = 'fHandBrakeForce', label = 'Handbrake Force',   category = 'brakes', min = 0.0,  max = 10.0, decimals = 3 },

    -- Traction -------------------------------------------------------------
    { name = 'fTractionCurveMax',         label = 'Traction Curve Max',   category = 'traction', min = 0.01, max = 5.0,  decimals = 3 },
    { name = 'fTractionCurveMin',         label = 'Traction Curve Min',   category = 'traction', min = 0.01, max = 5.0,  decimals = 3 },
    { name = 'fTractionCurveLateral',     label = 'Traction Lateral',     category = 'traction', min = 1.0,  max = 40.0, decimals = 2, unit = 'deg' },
    { name = 'fTractionSpringDeltaMax',   label = 'Traction Spring Delta',category = 'traction', min = 0.0,  max = 1.0,  decimals = 3 },
    { name = 'fLowSpeedTractionLossMult', label = 'Low Speed Grip Loss',  category = 'traction', min = 0.0,  max = 5.0,  decimals = 3 },
    { name = 'fCamberStiffnesss',         label = 'Camber Stiffness',     category = 'traction', min = -1.0, max = 1.0,  decimals = 3 },
    { name = 'fTractionBiasFront',        label = 'Traction Bias (Front)',category = 'traction', min = 0.01, max = 0.99, decimals = 3 },
    { name = 'fTractionLossMult',         label = 'Traction Loss Mult',   category = 'traction', min = 0.0,  max = 5.0,  decimals = 3 },
    { name = 'fSteeringLock',             label = 'Steering Lock',        category = 'traction', min = 5.0,  max = 90.0, decimals = 2, unit = 'deg' },

    -- Suspension -----------------------------------------------------------
    { name = 'fSuspensionForce',       label = 'Suspension Force',      category = 'suspension', min = 0.0,  max = 10.0, decimals = 3 },
    { name = 'fSuspensionCompDamp',    label = 'Compression Damping',   category = 'suspension', min = 0.0,  max = 10.0, decimals = 3 },
    { name = 'fSuspensionReboundDamp', label = 'Rebound Damping',       category = 'suspension', min = 0.0,  max = 10.0, decimals = 3 },
    { name = 'fSuspensionUpperLimit',  label = 'Suspension Upper Limit',category = 'suspension', min = -1.0, max = 1.0,  decimals = 3 },
    { name = 'fSuspensionLowerLimit',  label = 'Suspension Lower Limit',category = 'suspension', min = -1.0, max = 1.0,  decimals = 3 },
    { name = 'fSuspensionRaise',       label = 'Suspension Raise',      category = 'suspension', min = -1.0, max = 1.0,  decimals = 3 },
    { name = 'fSuspensionBiasFront',   label = 'Suspension Bias (Front)',category = 'suspension',min = 0.01, max = 0.99, decimals = 3 },
    { name = 'fAntiRollBarForce',      label = 'Anti-Roll Bar Force',   category = 'suspension', min = 0.0,  max = 10.0, decimals = 3 },
    { name = 'fAntiRollBarBiasFront',  label = 'Anti-Roll Bias (Front)',category = 'suspension', min = 0.01, max = 0.99, decimals = 3 },
    { name = 'fRollCentreHeightFront', label = 'Roll Centre Front',     category = 'suspension', min = -1.0, max = 1.0,  decimals = 3 },
    { name = 'fRollCentreHeightRear',  label = 'Roll Centre Rear',      category = 'suspension', min = -1.0, max = 1.0,  decimals = 3 },

    -- Chassis --------------------------------------------------------------
    { name = 'fMass',                 label = 'Mass',              category = 'chassis', min = 100.0, max = 50000.0, decimals = 1, unit = 'kg' },
    { name = 'fCollisionDamageMult',  label = 'Collision Damage',  category = 'chassis', min = 0.0,   max = 10.0,    decimals = 3 },
    { name = 'fWeaponDamageMult',     label = 'Weapon Damage',     category = 'chassis', min = 0.0,   max = 10.0,    decimals = 3 },
    { name = 'fDeformationDamageMult',label = 'Deformation Damage',category = 'chassis', min = 0.0,   max = 10.0,    decimals = 3 },
    { name = 'fEngineDamageMult',     label = 'Engine Damage',     category = 'chassis', min = 0.0,   max = 10.0,    decimals = 3 },
}

---Lookup by field name for the editable subset.
Fields.EditableByName = {}
for i = 1, #Fields.Editable do
    local field = Fields.Editable[i]
    local schema = Fields.ByName[field.name]

    -- Fail loudly at load rather than silently writing a field the game ignores.
    assert(schema, ('Fields.Editable references unknown handling field "%s"'):format(field.name))

    field.type = schema.type
    field.metaScale = schema.metaScale
    field.special = schema.special
    Fields.EditableByName[field.name] = field
end

---Editable fields grouped by category id.
Fields.ByCategory = {}
for i = 1, #Fields.Categories do
    Fields.ByCategory[Fields.Categories[i].id] = {}
end
for i = 1, #Fields.Editable do
    local field = Fields.Editable[i]
    local bucket = Fields.ByCategory[field.category]
    assert(bucket, ('field "%s" uses unknown category "%s"'):format(field.name, field.category))
    bucket[#bucket + 1] = field
end
