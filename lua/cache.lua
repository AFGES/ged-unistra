local M = {}
local sha256 = require("resty.sha256")
local str    = require("resty.string")

local DICT = "cas_session_cache"

-- Cache key matches the Node.js implementation:
-- "cookies_" + base64(username) + "_" + sha256hex(password)
function M.make_key(username, password)
    local h = sha256:new()
    h:update(password)
    local pw_hash = str.to_hex(h:final())
    return "cookies_" .. ngx.encode_base64(username) .. "_" .. pw_hash
end

-- Serialize as pipe-delimited: "jsessionid|b64(username)|timestamp"
-- None of these values contain "|"
function M.set(key, jsessionid, username, ttl)
    local value = jsessionid .. "|" .. ngx.encode_base64(username) .. "|" .. ngx.now()
    local ok, err, forcible = ngx.shared[DICT]:set(key, value, ttl)
    if not ok then
        ngx.log(ngx.ERR, "cache set failed: ", err)
    elseif forcible then
        ngx.log(ngx.WARN, "cache full, LRU eviction occurred")
    end
end

-- Returns jsessionid string or nil
function M.get(key)
    local value = ngx.shared[DICT]:get(key)
    if not value then return nil end
    return value:match("^([^|]+)|")
end

-- Per-key login lock so parallel cache misses run CAS only once.
-- Returns true if the caller now holds the lock.
function M.lock(key, ttl)
    return ngx.shared[DICT]:add("lock_" .. key, true, ttl) == true
end

function M.unlock(key)
    ngx.shared[DICT]:delete("lock_" .. key)
end

function M.is_locked(key)
    return ngx.shared[DICT]:get("lock_" .. key) ~= nil
end

function M.flush()
    ngx.shared[DICT]:flush_all()
    ngx.shared[DICT]:flush_expired()
end

function M.stats()
    local d = ngx.shared[DICT]
    local keys = d:get_keys(0)
    return {
        keys_count       = #keys,
        capacity_bytes   = d:capacity(),
        free_space_bytes = d:free_space(),
    }
end

return M
