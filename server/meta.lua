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
local META_PATH = 'data/handling.meta'
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
function Meta.Build(preserved)
    local blocks = {}

    for i = 1, #Config.Vehicles do
        local entry = Store.Get(Config.Vehicles[i].model)
        if entry then
            local block = Meta.BuildEntry(entry)
            if block then
                blocks[#blocks + 1] = block
            end
        end
    end

    if preserved then
        for i = 1, #preserved do
            blocks[#blocks + 1] = preserved[i]
        end
    end

    return table.concat({
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
    local raw = LoadResourceFile(RESOURCE, META_PATH)
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

    return loaded
end

--------------------------------------------------------------------------------
-- Writing to disk
--------------------------------------------------------------------------------
-- SaveResourceFile is the normal route, but it fails silently for several
-- unrelated reasons: a missing `data` directory (it does not create one), a
-- read-only or wrong-owner resource folder, or a build where it simply refuses
-- a subdirectory. Rather than guess, every route is attempted in turn, the
-- result is verified by reading the file back, and a failure reports exactly
-- which step failed and why.

-- NOTHING in this section may run at file scope beyond plain assignments.
-- The CitizenFX Lua runtime does not provide the full standard library -- there
-- is no `package`, and `io` / `os.execute` are not guaranteed either -- and a
-- load-time error here would abort the rest of this file, leaving Meta.Save
-- undefined while Meta.Load (declared above) still exists. Every optional
-- library is therefore probed lazily, inside a function, behind a type check.

---Last failure reason, surfaced to the menu so a broken save is not console-only.
Meta.lastError = nil

---@return boolean
local function hasIO()
    return type(io) == 'table' and type(io.open) == 'function'
end

---@return boolean
local function hasShell()
    return type(os) == 'table' and type(os.execute) == 'function'
end

---Absolute path of the resource folder, or nil when the native is unavailable.
---@return string?
local function resourceDirectory()
    if type(GetResourcePath) ~= 'function' then return nil end

    local ok, path = pcall(GetResourcePath, RESOURCE)
    if not ok or type(path) ~= 'string' or path == '' then return nil end

    return (path:gsub('[/\\]+$', ''))
end

---Derive the separator from the path itself rather than from `package.config`,
---which does not exist in this runtime.
---@param path string
---@return string separator, boolean isWindows
local function separatorFor(path)
    if path:find('\\', 1, true) then return '\\', true end
    return '/', false
end

---@return string? file, string? directory
local function absolutePaths()
    local base = resourceDirectory()
    if not base then return nil, nil end

    local separator = separatorFor(base)
    local directory = base .. separator .. 'data'

    return directory .. separator .. 'handling.meta', directory
end

---Best-effort mkdir. SaveResourceFile will not create the directory itself and
---there is no filesystem library available, so this shells out when it can.
---@param directory string
local function ensureDirectory(directory)
    if not hasShell() then return end

    local _, isWindows = separatorFor(directory)

    -- stderr is suppressed: a failure here is not fatal (the retry below
    -- reports properly) and the shell's message would only spam the console.
    local command = isWindows
        and ('mkdir "%s" 2>nul'):format(directory)
        or ('mkdir -p "%s" 2>/dev/null'):format(directory)

    pcall(os.execute, command)
end

---Write through the Lua io library, bypassing SaveResourceFile entirely.
---@param xml string
---@return boolean ok, string? err
local function directWrite(xml)
    if not hasIO() then
        return false, 'the io library is unavailable, cannot write directly'
    end

    local path, directory = absolutePaths()
    if not path then
        return false, 'GetResourcePath is unavailable, cannot resolve an absolute path'
    end

    local file, err = io.open(path, 'wb')

    if not file then
        -- Most likely the `data` directory is missing; make it and retry once.
        ensureDirectory(directory)
        file, err = io.open(path, 'wb')
    end

    if not file then
        return false, ('io.open("%s") failed: %s'):format(path, tostring(err))
    end

    local written, writeErr = file:write(xml)
    file:close()

    if not written then
        return false, ('write to "%s" failed: %s'):format(path, tostring(writeErr))
    end

    return true, nil
end

---Confirm the bytes actually landed, rather than trusting a return value.
---@param xml string
---@return boolean
local function readBackMatches(xml)
    local raw = LoadResourceFile(RESOURCE, META_PATH)
    if raw and #raw == #xml then return true end

    -- LoadResourceFile can miss a file written outside the resource system, so
    -- fall back to reading the absolute path directly.
    if not hasIO() then return false end

    local path = absolutePaths()
    if not path then return false end

    local file = io.open(path, 'rb')
    if not file then return false end

    local contents = file:read('a')
    file:close()

    return contents ~= nil and #contents == #xml
end

---Collect everything useful about why writing might be failing.
---@return string[]
function Meta.Diagnose()
    local lines = {}
    local function add(format, ...) lines[#lines + 1] = (format):format(...) end

    add('resource name     : %s', RESOURCE)
    add('resource path     : %s', resourceDirectory() or '<GetResourcePath unavailable>')

    local path, directory = absolutePaths()
    add('target file       : %s', path or '<unknown>')

    add('read access       : %s', LoadResourceFile(RESOURCE, META_PATH) and 'ok' or 'FAILED (file missing or unreadable)')

    if not hasIO() then
        add('io library        : UNAVAILABLE -- only SaveResourceFile can be used')
    elseif directory then
        local separator = separatorFor(directory)
        local probePath = directory .. separator .. '.vehedit_write_test'
        local probe, probeErr = io.open(probePath, 'wb')

        local function removeProbe(target)
            if type(os) == 'table' and type(os.remove) == 'function' then
                pcall(os.remove, target)
            end
        end

        if probe then
            probe:write('test')
            probe:close()
            removeProbe(probePath)
            add('data/ writable    : yes')
        else
            add('data/ writable    : NO (%s)', tostring(probeErr))

            local base = resourceDirectory()
            local rootPath = base and (base .. separator .. '.vehedit_write_test')
            local rootProbe = rootPath and io.open(rootPath, 'wb')

            if rootProbe then
                rootProbe:close()
                removeProbe(rootPath)
                add('resource writable : yes -- the "data" folder is missing, not a permission problem')
            else
                add('resource writable : NO -- the whole resource folder is read-only to the server process')
            end
        end
    end

    add('last error        : %s', Meta.lastError or 'none')

    return lines
end

local function reportFailure()
    print('[vehicle-editor] ============================================================')
    print(('[vehicle-editor] FAILED to write %s'):format(META_PATH))
    print('[vehicle-editor] Edits are held in memory but will be LOST on restart.')
    print('[vehicle-editor] ')

    for _, line in ipairs(Meta.Diagnose()) do
        print('[vehicle-editor]   ' .. line)
    end

    print('[vehicle-editor] ')
    print('[vehicle-editor] Common fixes:')
    print(('[vehicle-editor]   * create a "data" folder inside the %s resource'):format(RESOURCE))
    print('[vehicle-editor]   * make the resource folder writable by the user running FXServer')
    print('[vehicle-editor]   * on Linux:  chown -R fxserver:fxserver <resource folder>')
    print('[vehicle-editor]   * a resource on a read-only mount or inside a zip cannot be written to')
    print('[vehicle-editor] Run  vehedit_diag  in the console for this report at any time.')
    print('[vehicle-editor] ============================================================')
end

---Write the store out to data/handling.meta.
---@return boolean ok, string? err
function Meta.Save()
    local xml = Meta.Build(Meta.preserved)

    -- Pass the explicit length rather than -1; some builds mishandle the
    -- sentinel and write nothing while still reporting success.
    local saved = SaveResourceFile(RESOURCE, META_PATH, xml, #xml)

    if saved and readBackMatches(xml) then
        Meta.lastError = nil
        Store.debugPrint('wrote ' .. META_PATH)
        return true, nil
    end

    -- SaveResourceFile did not do it. Try the filesystem directly, which also
    -- creates the data directory if that was the problem.
    local ok, err = directWrite(xml)

    if ok and readBackMatches(xml) then
        Meta.lastError = nil
        print(('[vehicle-editor] wrote %s directly (SaveResourceFile refused it)'):format(META_PATH))
        return true, nil
    end

    Meta.lastError = err or 'SaveResourceFile and the direct write both failed verification'
    reportFailure()

    return false, Meta.lastError
end
