--[[
    Offline test suite.  Run from the resource root:  lua5.4 tests/run.lua
]]

local harness = dofile((arg[0]:match('^(.*)tests[/\\][^/\\]*$') or './') .. 'tests/harness.lua')
harness.load(true)

local passed, failed = 0, 0
local failures = {}

local function test(name, fn)
    local ok, err = pcall(fn)
    if ok then
        passed = passed + 1
        print(('  ok    %s'):format(name))
    else
        failed = failed + 1
        failures[#failures + 1] = ('%s\n        %s'):format(name, tostring(err))
        print(('  FAIL  %s\n        %s'):format(name, tostring(err)))
    end
end

local function assertEqual(actual, expected, message)
    if actual ~= expected then
        error(('%s: expected %s, got %s'):format(message or 'mismatch', tostring(expected), tostring(actual)), 2)
    end
end

local function assertClose(actual, expected, tolerance, message)
    if math.abs(actual - expected) > (tolerance or 1e-6) then
        error(('%s: expected ~%s, got %s'):format(message or 'mismatch', tostring(expected), tostring(actual)), 2)
    end
end

local function assertTrue(value, message)
    if not value then error(message or 'expected a truthy value', 2) end
end

local function resetStore()
    Store.tunes = {}
    Store.version = 0
    Meta.preserved = {}
    harness.files = {}
end

--------------------------------------------------------------------------------
print('\nunit conversion')
--------------------------------------------------------------------------------

test('scaled fields round-trip meta -> runtime -> meta', function()
    for i = 1, #Fields.All do
        local field = Fields.All[i]
        if field.type == 'float' and not field.special then
            local metaValue = 12.345
            local runtime = Util.ToRuntime(field, metaValue)
            assertClose(Util.ToMeta(field, runtime), metaValue, 1e-9, field.name)
        end
    end
end)

test('steering lock converts degrees to radians', function()
    local field = Fields.ByName['fSteeringLock']
    assertClose(Util.ToRuntime(field, 45.0), math.pi / 4, 1e-9, 'runtime radians')
    assertClose(Util.ToMeta(field, math.pi / 4), 45.0, 1e-9, 'meta degrees')
end)

test('top speed converts km/h to m/s', function()
    local field = Fields.ByName['fInitialDriveMaxFlatVel']
    assertClose(Util.ToRuntime(field, 180.0), 50.0, 1e-9, 'runtime m/s')
end)

test('drag coefficient is scaled by 10000', function()
    local field = Fields.ByName['fInitialDragCoeff']
    assertClose(Util.ToRuntime(field, 9.5), 0.00095, 1e-12, 'runtime drag')
end)

test('drive bias keeps pure FWD and RWD distinct from AWD', function()
    local field = Fields.ByName['fDriveBiasFront']

    assertClose(Util.ToRuntime(field, 0.0), 0.0, 1e-9, 'RWD runtime')
    assertClose(Util.ToRuntime(field, 1.0), 1.0, 1e-9, 'FWD runtime')
    assertClose(Util.ToRuntime(field, 0.5), 1.0, 1e-9, 'AWD runtime')

    -- Front alone cannot tell FWD from 50/50 AWD; the rear value can.
    assertClose(Util.ToMeta(field, 1.0, 0.0), 1.0, 1e-9, 'FWD back to meta')
    assertClose(Util.ToMeta(field, 1.0, 1.0), 0.5, 1e-9, 'AWD back to meta')
    assertClose(Util.ToMeta(field, 0.0, 1.0), 0.0, 1e-9, 'RWD back to meta')
end)

--------------------------------------------------------------------------------
print('\nvalidation')
--------------------------------------------------------------------------------

test('values are clamped to the field range', function()
    local value = Util.SanitizeValue('fInitialDriveForce', 999.0)
    assertEqual(value, Fields.EditableByName['fInitialDriveForce'].max, 'clamped high')

    value = Util.SanitizeValue('fInitialDriveForce', -50.0)
    assertEqual(value, Fields.EditableByName['fInitialDriveForce'].min, 'clamped low')
end)

test('non-finite and non-numeric values are rejected', function()
    assertEqual(Util.SanitizeValue('fMass', 0 / 0), nil, 'nan')
    assertEqual(Util.SanitizeValue('fMass', math.huge), nil, 'inf')
    assertEqual(Util.SanitizeValue('fMass', -math.huge), nil, '-inf')
    assertEqual(Util.SanitizeValue('fMass', 'banana'), nil, 'string')
end)

test('unknown fields are rejected', function()
    local value, err = Util.SanitizeValue('fNotARealField', 1.0)
    assertEqual(value, nil, 'value')
    assertTrue(err and err:find('not an editable field'), 'error message')
end)

test('integer fields round to integers', function()
    local value = Util.SanitizeValue('nInitialDriveGears', 6.7)
    assertEqual(value, 7, 'gears')
    assertEqual(math.type(value), 'integer', 'integer subtype')
end)

--------------------------------------------------------------------------------
print('\ntier rolls')
--------------------------------------------------------------------------------

test('every roll lands inside its tier band', function()
    math.randomseed(1)

    for tier = Config.MinTier, Config.MaxTier do
        local tierConfig = Config.Tiers[tier]
        assertTrue(tierConfig, 'tier ' .. tier .. ' exists')

        for _ = 1, 200 do
            local rolled = Util.RollTier(tierConfig)

            for fieldName, value in pairs(rolled) do
                local band = tierConfig.fields[fieldName]
                local field = Fields.EditableByName[fieldName]
                local low = math.max(band.min, field.min)
                local high = math.min(band.max, field.max)

                assertTrue(value >= low - 1e-6 and value <= high + 1e-6,
                    ('tier %d %s rolled %s outside [%s, %s]'):format(tier, fieldName, value, low, high))
            end
        end
    end
end)

test('integer bands roll integers', function()
    math.randomseed(2)
    for tier = Config.MinTier, Config.MaxTier do
        for _ = 1, 50 do
            local rolled = Util.RollTier(Config.Tiers[tier])
            local gears = rolled['nInitialDriveGears']
            if gears then
                assertEqual(math.type(gears), 'integer', 'tier ' .. tier .. ' gears integer')
            end
        end
    end
end)

test('every tier band names a real editable field', function()
    for tier = Config.MinTier, Config.MaxTier do
        for fieldName in pairs(Config.Tiers[tier].fields) do
            assertTrue(Fields.EditableByName[fieldName],
                ('tier %d references unknown field %s'):format(tier, fieldName))
        end
    end
end)

test('tier bands sit inside their field limits', function()
    for tier = Config.MinTier, Config.MaxTier do
        for fieldName, band in pairs(Config.Tiers[tier].fields) do
            local field = Fields.EditableByName[fieldName]
            assertTrue(band.min >= field.min and band.max <= field.max,
                ('tier %d band for %s [%s, %s] escapes the field limits [%s, %s]')
                    :format(tier, fieldName, band.min, band.max, field.min, field.max))
        end
    end
end)

test('every tier declares mod defaults', function()
    for tier = Config.MinTier, Config.MaxTier do
        local mods = Config.Tiers[tier].mods
        assertTrue(mods, 'tier ' .. tier .. ' has mods')
        for i = 1, #Config.ModTypes do
            local modType = Config.ModTypes[i]
            local level = mods[modType.id]
            assertTrue(level ~= nil, ('tier %d missing %s'):format(tier, modType.id))
            assertTrue(level >= -1 and level <= modType.max,
                ('tier %d %s level %s out of range'):format(tier, modType.id, level))
        end
    end
end)

--------------------------------------------------------------------------------
print('\nstore')
--------------------------------------------------------------------------------

test('unconfigured models are refused', function()
    resetStore()
    local ok, err = Store.SetValue('not_a_car', 'fMass', 1500)
    assertEqual(ok, false, 'refused')
    assertTrue(err and err:find('Config.Vehicles'), 'error mentions the config')
end)

test('edits are clamped on the way into the store', function()
    resetStore()
    Store.Ensure('sultan')
    assertTrue(Store.SetValue('sultan', 'fInitialDriveForce', 99.0), 'accepted')
    assertEqual(Store.Get('sultan').values.fInitialDriveForce,
        Fields.EditableByName['fInitialDriveForce'].max, 'clamped')
end)

test('originals are never overwritten once captured', function()
    resetStore()
    Store.SetOriginals('sultan', harness.fakeOriginals(1))
    local first = Store.Get('sultan').originals.fMass

    -- A second submission (e.g. from a client that spawned an already-tuned car)
    -- must not replace the real vanilla values.
    local second = harness.fakeOriginals(9)
    second.fMass = 99999.0
    assertEqual(Store.SetOriginals('sultan', second), false, 'second submission refused')
    assertEqual(Store.Get('sultan').originals.fMass, first, 'originals unchanged')
end)

test('resolved values are originals with edits on top', function()
    resetStore()
    Store.SetOriginals('sultan', harness.fakeOriginals(1))
    Store.SetValue('sultan', 'fBrakeForce', 1.25)

    local resolved = Store.ResolveValues('sultan')
    assertEqual(resolved.fBrakeForce, 1.25, 'edit applied')
    assertEqual(resolved.fMass, Store.Get('sultan').originals.fMass, 'untouched field is vanilla')
end)

test('resolution is withheld until vanilla values exist', function()
    resetStore()
    Store.Ensure('sultan')
    assertEqual(Store.ResolveValues('sultan'), nil, 'no partial set')
end)

test('mod overrides win over tier defaults', function()
    resetStore()
    Store.Ensure('sultan')
    Store.SetTier('sultan', 1)

    assertEqual(Store.ResolveMods('sultan').engine, Config.Tiers[1].mods.engine, 'tier default')

    Store.SetMod('sultan', 'engine', 3)
    assertEqual(Store.ResolveMods('sultan').engine, 3, 'override')

    Store.ClearMod('sultan', 'engine')
    assertEqual(Store.ResolveMods('sultan').engine, Config.Tiers[1].mods.engine, 'back to default')
end)

test('mod levels are clamped to the mod type maximum', function()
    resetStore()
    Store.Ensure('sultan')
    Store.SetMod('sultan', 'engine', 99)
    assertEqual(Store.Get('sultan').mods.engine, Config.ModTypeById['engine'].max, 'clamped')
end)

test('tier must be 1-5', function()
    resetStore()
    Store.Ensure('sultan')
    assertEqual(Store.SetTier('sultan', 0), false, 'below range')
    assertEqual(Store.SetTier('sultan', 6), false, 'above range')
    assertTrue(Store.SetTier('sultan', 5), 'in range')
end)

test('reset clears edits, overrides and tier', function()
    resetStore()
    Store.SetOriginals('sultan', harness.fakeOriginals(1))
    Store.SetValue('sultan', 'fBrakeForce', 1.25)
    Store.SetMod('sultan', 'engine', 3)
    Store.SetTier('sultan', 5)

    Store.Reset('sultan')

    local entry = Store.Get('sultan')
    assertEqual(next(entry.values), nil, 'no edits')
    assertEqual(next(entry.mods), nil, 'no overrides')
    assertEqual(entry.tier, Config.VehicleByModel['sultan'].tier, 'config tier restored')
    assertTrue(entry.originals, 'originals kept')
end)

test('the version bumps on every mutation', function()
    resetStore()
    Store.Ensure('sultan')
    local before = Store.version
    Store.SetValue('sultan', 'fBrakeForce', 1.1)
    assertTrue(Store.version > before, 'version moved')
end)

test('randomize touches only the fields its tier bands name', function()
    resetStore()
    Store.SetOriginals('sultan', harness.fakeOriginals(1))
    Store.SetTier('sultan', 4)
    Store.Randomize('sultan')

    local entry = Store.Get('sultan')
    for fieldName in pairs(entry.values) do
        assertTrue(Config.Tiers[4].fields[fieldName],
            ('%s was rolled but tier 4 declares no band for it'):format(fieldName))
    end
    assertTrue(next(entry.values), 'something was rolled')
end)

test('randomize all covers every configured vehicle', function()
    resetStore()
    for i = 1, #Config.Vehicles do
        Store.SetOriginals(Config.Vehicles[i].model, harness.fakeOriginals(i))
    end

    assertEqual(Store.RandomizeAll(), #Config.Vehicles, 'count')
    for i = 1, #Config.Vehicles do
        assertTrue(next(Store.Get(Config.Vehicles[i].model).values),
            Config.Vehicles[i].model .. ' was rolled')
    end
end)

test('the ace permission gates editing', function()
    harness.aceAllowed = {}
    assertEqual(Store.CanEdit(1), false, 'denied without the ace')

    harness.aceAllowed['1|' .. Config.AcePermission] = true
    assertEqual(Store.CanEdit(1), true, 'allowed with the ace')
    assertEqual(Store.CanEdit(0), true, 'console always allowed')
end)

--------------------------------------------------------------------------------
print('\nhandling.meta')
--------------------------------------------------------------------------------

local function seedFleet()
    resetStore()
    for i = 1, #Config.Vehicles do
        Store.SetOriginals(Config.Vehicles[i].model, harness.fakeOriginals(i))
    end
end

test('an entry writes every field in the schema', function()
    seedFleet()
    local xml = Meta.BuildEntry(Store.Get('sultan'))
    assertTrue(xml, 'entry built')

    for i = 1, #Fields.All do
        local field = Fields.All[i]
        assertTrue(xml:find('<' .. field.name, 1, true),
            ('handling.meta entry is missing <%s>'):format(field.name))
    end

    assertTrue(xml:find('<handlingName>SULTAN</handlingName>', 1, true), 'handling name')
    assertTrue(xml:find('<SubHandlingData>', 1, true), 'subhandling block')
end)

test('no entry is written without vanilla values', function()
    resetStore()
    Store.Ensure('sultan')
    assertEqual(Meta.BuildEntry(Store.Get('sultan')), nil, 'refused to write a partial entry')
end)

test('build then parse round-trips tier, originals, edits and mods', function()
    seedFleet()
    Store.SetTier('sultan', 5)
    Store.SetValue('sultan', 'fInitialDriveForce', 0.47)
    Store.SetValue('sultan', 'fBrakeForce', 1.42)
    Store.SetMod('sultan', 'engine', 3)
    Store.SetMod('sultan', 'turbo', true)

    local before = Store.Get('sultan')
    local xml = Meta.Build()
    local tunes = Meta.Parse(xml)
    local after = tunes['sultan']

    assertTrue(after, 'sultan survived the round trip')
    assertEqual(after.tier, 5, 'tier')
    assertClose(after.values.fInitialDriveForce, 0.47, 1e-9, 'drive force edit')
    assertClose(after.values.fBrakeForce, 1.42, 1e-9, 'brake force edit')
    assertEqual(after.mods.engine, 3, 'engine override')
    assertEqual(after.mods.turbo, true, 'turbo override')

    for name, value in pairs(before.originals) do
        if type(value) == 'table' then
            assertClose(after.originals[name].x, value.x, 1e-6, name .. '.x')
            assertClose(after.originals[name].y, value.y, 1e-6, name .. '.y')
            assertClose(after.originals[name].z, value.z, 1e-6, name .. '.z')
        else
            assertClose(after.originals[name], value, 1e-6, name)
        end
    end
end)

test('a save followed by a restart restores the same state', function()
    seedFleet()
    Store.SetTier('adder', 5)
    Store.Randomize('adder')
    local expected = Store.Get('adder').values.fInitialDriveForce
    assertTrue(expected, 'adder was rolled')

    assertTrue(Meta.Save(), 'saved')

    -- Simulate a restart: memory is gone, only the file remains.
    Store.tunes = {}
    Store.version = 0
    assertTrue(Meta.Load() > 0, 'reloaded from file')

    assertClose(Store.Get('adder').values.fInitialDriveForce, expected, 1e-9,
        'drive force survived the restart')
    assertEqual(Store.Get('adder').tier, 5, 'tier survived the restart')
    assertTrue(Store.ResolveValues('adder'), 'resolvable straight after load')
end)

test('foreign entries in the file are preserved across a save', function()
    seedFleet()

    local foreign = table.concat({
        '    <Item type="CHandlingData">',
        '      <handlingName>MYCUSTOMCAR</handlingName>',
        '      <fMass value="1500.000000" />',
        '      <SubHandlingData>',
        '        <Item type="CCarHandlingData">',
        '          <fBackEndPopUpCarImpulseMult value="0.100000" />',
        '        </Item>',
        '      </SubHandlingData>',
        '    </Item>',
    }, '\n')

    harness.files['data/handling.meta'] = table.concat({
        '<?xml version="1.0" encoding="UTF-8"?>',
        '<CHandlingDataMgr>',
        '  <HandlingData>',
        foreign,
        '  </HandlingData>',
        '</CHandlingDataMgr>',
    }, '\n')

    Meta.Load()
    assertEqual(#Meta.preserved, 1, 'one foreign entry recognised')

    Meta.Save()
    local written = harness.files['data/handling.meta']
    assertTrue(written:find('MYCUSTOMCAR', 1, true), 'foreign entry survived the write')
    assertTrue(written:find('CCarHandlingData', 1, true), 'nested subhandling survived')
end)

test('nested subhandling items do not break entry detection', function()
    seedFleet()
    Meta.Save()

    local withForeign = harness.files['data/handling.meta']:gsub('</HandlingData>', table.concat({
        '    <Item type="CHandlingData">',
        '      <handlingName>NESTED</handlingName>',
        '      <SubHandlingData>',
        '        <Item type="CCarHandlingData">',
        '          <fBackEndPopUpCarImpulseMult value="0.100000" />',
        '        </Item>',
        '      </SubHandlingData>',
        '    </Item>',
        '  </HandlingData>',
    }, '\n'), 1)

    local tunes, preserved = Meta.Parse(withForeign)

    local managed = 0
    for _ in pairs(tunes) do managed = managed + 1 end

    assertEqual(managed, #Config.Vehicles, 'all managed entries still found')
    assertEqual(#preserved, 1, 'the nested foreign entry was isolated')
    assertTrue(preserved[1]:find('NESTED', 1, true), 'correct entry preserved')
end)

test('models dropped from the config stop being managed', function()
    seedFleet()
    Meta.Save()

    local saved = Config.VehicleByModel['adder']
    Config.VehicleByModel['adder'] = nil

    Store.tunes = {}
    Meta.Load()
    assertEqual(Store.Get('adder'), nil, 'adder is no longer managed')

    Config.VehicleByModel['adder'] = saved
end)

test('the generated file is well-formed XML', function()
    seedFleet()
    Store.SetValue('sultan', 'fBrakeForce', 1.2)

    local xml = Meta.Build()

    local opens = select(2, xml:gsub('<Item[^>]*[^/]>', ''))
    local closes = select(2, xml:gsub('</Item>', ''))
    assertEqual(opens, closes, 'balanced <Item> tags')

    assertTrue(xml:find('<?xml version="1.0" encoding="UTF-8"?>', 1, true), 'xml declaration')
    assertTrue(xml:find('<CHandlingDataMgr>', 1, true), 'root element')
    assertTrue(xml:find('</CHandlingDataMgr>', 1, true), 'root closed')

    -- An unescaped `--` inside a comment would terminate it early and corrupt
    -- everything after it.
    for comment in xml:gmatch('<!%-%-(.-)%-%->') do
        assertEqual(comment:find('%-%-'), nil, 'no stray -- inside a comment')
    end
end)

test('flags are written as hex', function()
    seedFleet()
    local xml = Meta.BuildEntry(Store.Get('sultan'))
    assertTrue(xml:find('<strModelFlags>440010</strModelFlags>', 1, true), 'model flags in hex')
end)

test('vectors are written with x/y/z attributes', function()
    seedFleet()
    local xml = Meta.BuildEntry(Store.Get('sultan'))
    assertTrue(xml:match('<vecCentreOfMassOffset x="[-%d%.]+" y="[-%d%.]+" z="[-%d%.]+" />'), 'centre of mass')
end)

--------------------------------------------------------------------------------
print('\nconfig integrity')
--------------------------------------------------------------------------------

test('every editable field exists in the schema', function()
    for i = 1, #Fields.Editable do
        assertTrue(Fields.ByName[Fields.Editable[i].name], Fields.Editable[i].name)
    end
end)

test('every editable field has a sane range', function()
    for i = 1, #Fields.Editable do
        local field = Fields.Editable[i]
        assertTrue(field.min < field.max, ('%s has min >= max'):format(field.name))
        assertTrue(field.decimals ~= nil, ('%s has no decimals'):format(field.name))
    end
end)

test('configured vehicles have a tier that exists', function()
    for i = 1, #Config.Vehicles do
        local vehicle = Config.Vehicles[i]
        assertTrue(Config.Tiers[vehicle.tier], ('%s has no tier %s'):format(vehicle.model, vehicle.tier))
    end
end)

test('every category holds at least one field', function()
    for i = 1, #Fields.Categories do
        local category = Fields.Categories[i]
        assertTrue(#Fields.ByCategory[category.id] > 0, category.id .. ' is empty')
    end
end)

--------------------------------------------------------------------------------

print(('\n%d passed, %d failed'):format(passed, failed))

if failed > 0 then
    print('\nfailures:')
    for i = 1, #failures do print('  - ' .. failures[i]) end
    os.exit(1)
end

os.exit(0)
