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

---Write the store out to data/handling.meta.
---@return boolean ok
function Meta.Save()
    local xml = Meta.Build(Meta.preserved)
    local ok = SaveResourceFile(RESOURCE, META_PATH, xml, -1)

    if ok then
        Store.debugPrint('wrote ' .. META_PATH)
    else
        print(('[vehicle-editor] FAILED to write %s -- is the resource folder writable?'):format(META_PATH))
    end

    return ok and true or false
end
