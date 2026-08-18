--[[
    Minimal JSON encode/decode standing in for the `json` global FiveM provides.
    Test-only; the resource itself uses the runtime's implementation.
]]

local json = {}

local function encodeValue(value, out)
    local valueType = type(value)

    if value == nil then
        out[#out + 1] = 'null'
    elseif valueType == 'boolean' then
        out[#out + 1] = tostring(value)
    elseif valueType == 'number' then
        if value ~= value or value == math.huge or value == -math.huge then
            error('cannot encode non-finite number')
        end
        if math.type(value) == 'integer' then
            out[#out + 1] = ('%d'):format(value)
        else
            out[#out + 1] = ('%.17g'):format(value)
        end
    elseif valueType == 'string' then
        out[#out + 1] = '"' .. value:gsub('[%c"\\]', function(char)
            return ('\\u%04x'):format(char:byte())
        end) .. '"'
    elseif valueType == 'table' then
        local count = 0
        for _ in pairs(value) do count = count + 1 end

        if count == #value then
            out[#out + 1] = '['
            for i = 1, #value do
                if i > 1 then out[#out + 1] = ',' end
                encodeValue(value[i], out)
            end
            out[#out + 1] = ']'
        else
            local keys = {}
            for key in pairs(value) do keys[#keys + 1] = key end
            table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)

            out[#out + 1] = '{'
            for i = 1, #keys do
                if i > 1 then out[#out + 1] = ',' end
                encodeValue(tostring(keys[i]), out)
                out[#out + 1] = ':'
                encodeValue(value[keys[i]], out)
            end
            out[#out + 1] = '}'
        end
    else
        error('cannot encode ' .. valueType)
    end
end

function json.encode(value)
    local out = {}
    encodeValue(value, out)
    return table.concat(out)
end

local decodeValue

local function skipSpace(text, position)
    local _, last = text:find('^[ \t\r\n]*', position)
    return last + 1
end

local function decodeString(text, position)
    local out = {}
    position = position + 1

    while true do
        local char = text:sub(position, position)
        if char == '' then error('unterminated string') end
        if char == '"' then return table.concat(out), position + 1 end

        if char == '\\' then
            local escape = text:sub(position + 1, position + 1)
            if escape == 'u' then
                out[#out + 1] = string.char(tonumber(text:sub(position + 2, position + 5), 16) % 256)
                position = position + 6
            else
                local map = { n = '\n', t = '\t', r = '\r', b = '\b', f = '\f' }
                out[#out + 1] = map[escape] or escape
                position = position + 2
            end
        else
            out[#out + 1] = char
            position = position + 1
        end
    end
end

function decodeValue(text, position)
    position = skipSpace(text, position)
    local char = text:sub(position, position)

    if char == '{' then
        local object = {}
        position = skipSpace(text, position + 1)
        if text:sub(position, position) == '}' then return object, position + 1 end

        while true do
            local key
            key, position = decodeString(text, skipSpace(text, position))
            position = skipSpace(text, position)
            assert(text:sub(position, position) == ':', 'expected :')
            local value
            value, position = decodeValue(text, position + 1)
            object[key] = value

            position = skipSpace(text, position)
            local delimiter = text:sub(position, position)
            if delimiter == ',' then
                position = position + 1
            elseif delimiter == '}' then
                return object, position + 1
            else
                error('expected , or } near ' .. position)
            end
        end
    elseif char == '[' then
        local array = {}
        position = skipSpace(text, position + 1)
        if text:sub(position, position) == ']' then return array, position + 1 end

        while true do
            local value
            value, position = decodeValue(text, position)
            array[#array + 1] = value

            position = skipSpace(text, position)
            local delimiter = text:sub(position, position)
            if delimiter == ',' then
                position = position + 1
            elseif delimiter == ']' then
                return array, position + 1
            else
                error('expected , or ] near ' .. position)
            end
        end
    elseif char == '"' then
        return decodeString(text, position)
    elseif text:sub(position, position + 3) == 'true' then
        return true, position + 4
    elseif text:sub(position, position + 4) == 'false' then
        return false, position + 5
    elseif text:sub(position, position + 3) == 'null' then
        return nil, position + 4
    else
        local numberText = text:match('^-?%d+%.?%d*[eE]?[-+]?%d*', position)
        if not numberText or numberText == '' then
            error('unexpected character at ' .. position .. ': ' .. char)
        end
        return tonumber(numberText), position + #numberText
    end
end

function json.decode(text)
    local value = decodeValue(text, 1)
    return value
end

return json
