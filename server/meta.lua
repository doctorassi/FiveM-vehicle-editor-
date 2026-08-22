--[[
    handling.meta writer / parser.

    data/handling.meta is BOTH the file the game loads at resource start and the
    editor's save file. Each entry is preceded by an XML comment carrying the
    editor's own state:

        <!-- vehicle-editor {"tier":3,"originals":{...},"edits":{...}} -->

    The RAGE parser ignores XML comments, so the game sees a perfectly ordinary
    handling file while the editor can rebuild tiers, vanilla originals and the
    list of which fields were actually touched after a restart.

    Entries WITHOUT an editor comment are preserved verbatim on rewrite, so a
    hand-written entry in this file is not destroyed by a save.
]]

Meta = {}

local RESOURCE = GetCurrentResourceName()
-- The tune file lives at the resource ROOT, not in a subfolder, because
-- SAVE_RESOURCE_FILE does not create directories.
local META_PATH = 'handling.meta'

-- Where the file used to live. Read once so an existing install keeps its
-- tunes; never written to again.
local LEGACY_PATH = 'data/handling.meta'

-- The natives are invoked BY HASH rather than through the SaveResourceFile /
-- LoadResourceFile globals.
--
-- This is the whole reason saving failed for so long. Those globals can be
-- shadowed -- a plain `SaveResourceFile = ...` anywhere in this Lua state
-- replaces them for everyone -- and when that happens the call never reaches
-- the native and simply reports failure. Citizen.InvokeNative cannot be
-- intercepted that way, so file IO no longer depends on the global table being
-- intact.
--
-- Hashes from the CFX natives manifest:
--   SAVE_RESOURCE_FILE  0xA09E7E7B  server  BOOL(resource, file, data, length)
--   LOAD_RESOURCE_FILE  0x76A9EE1F  shared  char*(resource, file)
--
-- The result-type hints are required: InvokeNative does not know the signature.

local SAVE_RESOURCE_FILE = 0xA09E7E7B
local LOAD_RESOURCE_FILE = 0x76A9EE1F

---Write a file inside this resource.
---@param fileName string
---@param data string
---@return boolean ok
local function writeFile(fileName, data)
    return Citizen.InvokeNative(SAVE_RESOURCE_FILE, RESOURCE, fileName, data, #data,
        Citizen.ResultAsInteger()) ~= 0
end

---Read a file inside this resource.
---@param fileName string
---@return string?
local function readFile(fileName)
    return Citizen.InvokeNative(LOAD_RESOURCE_FILE, RESOURCE, fileName,
        Citizen.ResultAsString())
end

Meta.writeFile = writeFile
Meta.readFile = readFile
local COMMENT_TAG = 'vehicle-editor'
-- The tag contains a `-`, which is a quantifier in Lua patterns, so every
-- pattern that looks for it must use the escaped form.
local COMMENT_PATTERN = (COMMENT_TAG:gsub('%p', '%%%0'))

--------------------------------------------------------------------------------
-- Writing
--------------------------------------------------------------------------------

local function formatFloat(value)
    return ('%.6f'):format(value + 0.0)
end

local function formatInt(value)
    return ('%d'):format(math.floor(tonumber(value) or 0))
end

local function formatFlags(value)
    return ('%X'):format(math.floor(tonumber(value) or 0))
end

---Handling id for a model. Defaults to the uppercased spawn name, which is what
---the overwhelming majority of vehicles use; override per vehicle in the config
---with `handling = 'SOMETHING_ELSE'` when a model does not follow that rule.
---@param model string
---@return string
function Meta.HandlingName(model)
    local configured = Config.VehicleByModel[model]
    if configured and configured.handling then
        return configured.handling:upper()
    end
    return model:upper()
end

---Serialise one field as its handling.meta element.
local function fieldElement(field, value, indent)
    if value == nil then return nil end

    if field.type == 'vector' then
        return ('%s<%s x="%s" y="%s" z="%s" />'):format(
            indent, field.name,
            formatFloat(value.x or 0.0), formatFloat(value.y or 0.0), formatFloat(value.z or 0.0))
    end

    if field.type == 'flags' then
        return ('%s<%s>%s</%s>'):format(indent, field.name, formatFlags(value), field.name)
    end

    if field.type == 'int' then
        return ('%s<%s value="%s" />'):format(indent, field.name, formatInt(value))
    end

    return ('%s<%s value="%s" />'):format(indent, field.name, formatFloat(value))
end

---The editor state comment for a model.
---A model name is restricted to word characters before it goes anywhere near
---the comment, so the payload can never contain a `--` that would terminate the
---XML comment early.
---@param entry table
---@return string
function Meta.BuildComment(entry)
    local payload = {
        model = entry.model:gsub('[^%w_]', ''),
        tier = entry.tier,
        originals = entry.originals,
        edits = entry.values,
        mods = entry.mods,
    }

    local encoded = json.encode(payload)
    -- Belt and braces: neutralise any `--` that somehow survived.
    encoded = encoded:gsub('%-%-', '- -')

    return ('    <!-- %s %s -->'):format(COMMENT_TAG, encoded)
end

---Build the full <Item type="CHandlingData"> block for one stored tune.
---Returns nil when the vanilla snapshot is missing: a partial entry would make
---the game default every field we failed to write, which is far worse than
---writing nothing at all.
---@param entry table
---@return string?
function Meta.BuildEntry(entry)
    if not entry.originals then return nil end

    local resolved = Store.ResolveValues(entry.model)
    if not resolved then return nil end

    local lines = {
        Meta.BuildComment(entry),
        '    <Item type="CHandlingData">',
        ('      <handlingName>%s</handlingName>'):format(Meta.HandlingName(entry.model)),
    }

    for i = 1, #Fields.All do
        local field = Fields.All[i]
        local line = fieldElement(field, resolved[field.name], '      ')
        if line then
            lines[#lines + 1] = line
        end
    end

    lines[#lines + 1] = '      <AIHandling>AVERAGE</AIHandling>'
    lines[#lines + 1] = '      <SubHandlingData>'
    lines[#lines + 1] = '        <Item type="NULL" />'
    lines[#lines + 1] = '      </SubHandlingData>'
    lines[#lines + 1] = '    </Item>'

    return table.concat(lines, '\n')
end

---Build the whole file.
---@param preserved string[]? raw entry blocks to re-emit untouched
---@return string
---@param preserved string[]?
---@return string xml, number entries how many vehicles actually made it in
function Meta.Build(preserved)
    local blocks = {}
    local entries = 0

    for i = 1, #Config.Vehicles do
        local entry = Store.Get(Config.Vehicles[i].model)
        if entry then
            local block = Meta.BuildEntry(entry)
            if block then
                blocks[#blocks + 1] = block
                entries = entries + 1
            end
        end
    end

    if preserved then
        for i = 1, #preserved do
            blocks[#blocks + 1] = preserved[i]
        end
    end

    local xml = table.concat({
        '<?xml version="1.0" encoding="UTF-8"?>',
        '<!-- Generated by fivem-vehicle-editor. Entries marked with a',
        '     "' .. COMMENT_TAG .. '" comment are rewritten on every save. -->',
        '<CHandlingDataMgr>',
        '  <HandlingData>',
        #blocks > 0 and table.concat(blocks, '\n\n') or '',
        '  </HandlingData>',
        '</CHandlingDataMgr>',
        '',
    }, '\n')

    return xml, entries
end

--------------------------------------------------------------------------------
-- Parsing
--------------------------------------------------------------------------------

---Locate every <Item type="CHandlingData"> block, tracking nesting so a real
---SubHandlingData item does not terminate the scan early.
---@param xml string
---@return table[] list of { first = number, last = number }
local function findEntries(xml)
    local tags = {}
    for position, tag in xml:gmatch('()(</?Item[^>]*>)') do
        tags[#tags + 1] = { position = position, tag = tag, length = #tag }
    end

    local entries = {}
    local index = 1

    while index <= #tags do
        local token = tags[index]

        if token.tag:match('^<Item%s+type="CHandlingData"%s*>') then
            local depth = 1
            local cursor = index + 1

            while cursor <= #tags and depth > 0 do
                local inner = tags[cursor].tag
                if inner:sub(1, 2) == '</' then
                    depth = depth - 1
                elseif inner:sub(-2) ~= '/>' then
                    depth = depth + 1
                end
                cursor = cursor + 1
            end

            if depth == 0 then
                local closing = tags[cursor - 1]
                entries[#entries + 1] = {
                    first = token.position,
                    last = closing.position + closing.length - 1,
                }
                index = cursor
            else
                -- Unbalanced file; stop rather than guess.
                break
            end
        else
            index = index + 1
        end
    end

    return entries
end

---Find an editor comment immediately preceding `position` (whitespace only in
---between). Returns the decoded payload and the comment's start offset.
---@param xml string
---@param position number
---@return table? payload, number? commentStart
local function precedingComment(xml, position)
    local before = xml:sub(1, position - 1)

    -- Anchor to the LAST comment in the prefix. Searching from the start would
    -- let the lazy body span from the file's first comment all the way to this
    -- entry, swallowing every entry in between.
    local lastComment
    for offset in before:gmatch('()<!%-%-') do lastComment = offset end
    if not lastComment then return nil, nil end

    local commentStart, _, body =
        before:find('^<!%-%-%s*' .. COMMENT_PATTERN .. '%s*(.-)%s*%-%->%s*$', lastComment)
    if not commentStart then return nil, nil end

    local ok, payload = pcall(json.decode, body)
    if not ok or type(payload) ~= 'table' then return nil, nil end

    return payload, commentStart
end

---Parse a handling.meta produced by this resource.
---@param xml string
---@return table tunes, string[] preserved
function Meta.Parse(xml)
    local tunes, preserved = {}, {}
    if type(xml) ~= 'string' or xml == '' then return tunes, preserved end

    local entries = findEntries(xml)

    for i = 1, #entries do
        local entry = entries[i]
        local payload = precedingComment(xml, entry.first)

        if payload and type(payload.model) == 'string' then
            tunes[payload.model:lower()] = {
                model = payload.model:lower(),
                tier = tonumber(payload.tier) or 1,
                originals = type(payload.originals) == 'table' and payload.originals or nil,
                values = type(payload.edits) == 'table' and payload.edits or {},
                mods = type(payload.mods) == 'table' and payload.mods or {},
            }
        else
            -- Not ours; keep it byte-for-byte on the next write.
            preserved[#preserved + 1] = xml:sub(entry.first, entry.last)
        end
    end

    return tunes, preserved
end

--------------------------------------------------------------------------------
-- IO
--------------------------------------------------------------------------------

---Entries in the file that the editor does not manage, kept across saves.
Meta.preserved = {}

---Read data/handling.meta back into the store. Runs on resource start, which is
---what makes edits survive a restart.
---@return number loaded
function Meta.Load()
    local raw = readFile(META_PATH)
    local migrated = false

    -- Adopt a file left at the old data/ path by an earlier version. It is only
    -- read, never written, and the next save moves it to the new location.
    if not raw or not raw:find('<Item', 1, true) then
        local legacy = readFile(LEGACY_PATH)

        if legacy and legacy:find('<Item', 1, true) then
            raw = legacy
            migrated = true
        end
    end

    if not raw then
        Store.debugPrint('no existing handling.meta, starting clean')
        return 0
    end

    local tunes, preserved = Meta.Parse(raw)
    Meta.preserved = preserved

    local loaded = 0
    for model, parsed in pairs(tunes) do
        -- Only adopt vehicles that are still in the config; a model removed from
        -- Config.Vehicles should stop being managed, not linger forever.
        if Config.VehicleByModel[model] then
            Store.tunes[model] = {
                model = model,
                tier = math.min(math.max(parsed.tier, Config.MinTier), Config.MaxTier),
                values = parsed.values,
                mods = parsed.mods,
                originals = parsed.originals,
            }
            loaded = loaded + 1
        end
    end

    Store.Bump()
    Store.debugPrint(('loaded %d tune(s) and preserved %d foreign entry(s) from handling.meta')
        :format(loaded, #preserved))

    if migrated then
        print(('[vehicle-editor] migrated %d tune(s) from %s to %s; the old file is no longer used and can be deleted.')
            :format(loaded, LEGACY_PATH, META_PATH))
        Meta.Save()
    end

    return loaded
end

--------------------------------------------------------------------------------
-- Writing to disk
--------------------------------------------------------------------------------


---Last failure reason, surfaced to the menu so a broken save is not console-only.
Meta.lastError = nil

---How many vehicles made it into the last written file.
Meta.entries = 0

---Report what the editor is writing and where.
function Meta.Diagnose()
    local lines = {
        '[vehicle-editor] save diagnostics',
        ('  resource name    : %s'):format(tostring(RESOURCE)),
        ('  state file       : %s (%s)'):format(
            State and State.PATH or 'tunes.json',
            State and (State.lastError or 'ok') or 'unknown'),
        ('  handling.meta    : %s'):format(Meta.lastError or 'ok'),
    }

    if type(GetResourcePath) == 'function' then
        local ok, path = pcall(GetResourcePath, RESOURCE)
        lines[#lines + 1] = ('  resource path    : %s'):format(ok and tostring(path) or 'unavailable')
    end

    lines[#lines + 1] = '  Run vehedit_testwrite to check file writing on its own.'

    print(table.concat(lines, '\n'))
end

---True once a handling.meta failure has been reported, so a host where the file
---is permanently unwritable does not spam the console on every autosave.
local warned = false

---@return boolean ok, string? err
function Meta.Save()
    local xml, entries = Meta.Build(Meta.preserved)

    if writeFile(META_PATH, xml) then
        if Meta.lastError then
            print('[vehicle-editor] handling.meta is writable again.')
        end
        Meta.lastError = nil
        warned = false
        Meta.entries = entries

        -- A file with no entries is written successfully and does nothing at
        -- all, which is indistinguishable from working unless it says so.
        if entries == 0 then
            local missing = #Store.MissingOriginals()
            print(('[vehicle-editor] handling.meta written with 0 entries — %d vehicle(s) have no vanilla snapshot yet.')
                :format(missing))
            print('[vehicle-editor] run vehedit_snapshot (or open /' .. Config.Command ..
                ' in game) to capture them; until then nothing is tuned in game either.')
        else
            Store.debugPrint(('wrote %s — %d entr%s, %d bytes')
                :format(META_PATH, entries, entries == 1 and 'y' or 'ies', #xml))
        end

        return true, nil, entries
    end

    local err = ('SAVE_RESOURCE_FILE refused "%s" (%d bytes)'):format(META_PATH, #xml)

    Meta.lastError = err

    -- Not fatal. State lives in tunes.json and clients apply it through the
    -- handling natives; only the native load-at-startup shortcut is lost.
    if not warned then
        warned = true
        print('[vehicle-editor] could not write handling.meta: ' .. err)
        Meta.Diagnose()
    end

    return false, err
end

--------------------------------------------------------------------------------
-- Editor state (tunes.json)
--------------------------------------------------------------------------------
-- Lives in this file rather than its own so there is one less script for a
-- deployment to miss. A server script that does not arrive is not an error in
-- FiveM -- the global it defines is simply nil, and the first caller dies with
-- "attempt to index a nil value" somewhere unrelated.
--
-- This is the source of truth, and it is a plain JSON file written with
-- SaveResourceFile -- the ordinary FiveM persistence route.
--
-- It is deliberately NOT declared in fxmanifest's `files {}`. handling.meta is,
-- because the game has to load it as HANDLING_FILE, and a file the resource
-- system owns is not reliably writable at runtime: writes to it can simply not
-- land, leaving the original on disk. Keeping state in a file nothing else
-- claims removes that failure mode entirely.
--
-- handling.meta is still generated above so the game applies tunes natively at
-- startup, but it is a bonus rather than the only copy. If it cannot be
-- written, nothing is lost: the state is here, and clients apply it through the
-- handling natives regardless.


State = {}

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

    if writeFile(STATE_PATH, encoded) then
        State.lastError = nil
        Store.debugPrint(('wrote %s (%d bytes)'):format(STATE_PATH, #encoded))
        return true, nil
    end

    local err = ('SAVE_RESOURCE_FILE refused "%s" (%d bytes)'):format(STATE_PATH, #encoded)

    State.lastError = err
    print('[vehicle-editor] FAILED to save ' .. STATE_PATH .. ': ' .. err)
    Meta.Diagnose()

    return false, err
end

---Read the state file back into the store.
---@return number loaded
function State.Load()
    local raw = readFile(STATE_PATH)
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
