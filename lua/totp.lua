local M   = {}
local bit = require("bit")

local B32_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"
local B32_INDEX    = {}
for i = 1, #B32_ALPHABET do
    B32_INDEX[B32_ALPHABET:sub(i, i)] = i - 1
end

-- Normalize a user-supplied secret: drop spaces/padding, upper-case.
function M.normalize(secret)
    return (secret:gsub("[%s=]", "")):upper()
end

-- True if the string looks like a usable base32 TOTP secret.
function M.is_secret(s)
    local n = M.normalize(s)
    return #n >= 16 and n:match("^[A-Z2-7]+$") ~= nil
end

-- True if the string is a ready-to-use 6-digit code.
function M.is_code(s)
    return s:match("^%d%d%d%d%d%d$") ~= nil
end

-- RFC 4648 base32 decode. Returns raw bytes or nil on invalid input.
local function base32_decode(s)
    local out, buffer, bits = {}, 0, 0
    for i = 1, #s do
        local v = B32_INDEX[s:sub(i, i)]
        if not v then return nil end
        buffer = bit.bor(bit.lshift(buffer, 5), v)
        bits = bits + 5
        if bits >= 8 then
            bits = bits - 8
            out[#out + 1] = string.char(bit.band(bit.rshift(buffer, bits), 0xFF))
        end
        buffer = bit.band(buffer, bit.lshift(1, bits) - 1)
    end
    return table.concat(out)
end

-- RFC 6238 TOTP (HMAC-SHA1, 30 s step, 6 digits).
-- Returns the code as a zero-padded string, or nil, err.
function M.code(secret, t)
    local key = base32_decode(M.normalize(secret))
    if not key or #key == 0 then
        return nil, "invalid base32 TOTP secret"
    end

    -- 8-byte big-endian counter; the high 32 bits are 0 until year 2106+.
    local counter = math.floor((t or ngx.time()) / 30)
    local msg = string.char(0, 0, 0, 0,
        bit.band(bit.rshift(counter, 24), 0xFF),
        bit.band(bit.rshift(counter, 16), 0xFF),
        bit.band(bit.rshift(counter, 8), 0xFF),
        bit.band(counter, 0xFF))

    local h = ngx.hmac_sha1(key, msg)
    local offset = bit.band(h:byte(20), 0x0F)
    local b1, b2, b3, b4 = h:byte(offset + 1, offset + 4)
    local bin = bit.bor(
        bit.lshift(bit.band(b1, 0x7F), 24),
        bit.lshift(b2, 16),
        bit.lshift(b3, 8),
        b4)

    return string.format("%06d", bin % 1000000), nil
end

return M
