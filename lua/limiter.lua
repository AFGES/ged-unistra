local M      = {}
local config = require("config")

-- Failed CAS logins per username and per client address, in the shared dict that cas_auth.lua uses for its
-- login locks. Past a limit, the proxy stops calling CAS until the window expires: a password-guessing
-- client cannot use it to lock a Unistra account, or to get AFGES's address blocked by CAS.
local DICT = "cas_auth_state"

local function user_key(username)
    return "failures_user_" .. ngx.encode_base64(username)
end

local function ip_key(ip)
    return "failures_ip_" .. (ip or "unknown")
end

-- Seconds left before the key's window ends (at least 1).
local function retry_after(dict, key)
    local ttl = dict:ttl(key)
    if not ttl or ttl < 1 then return 1 end
    return math.ceil(ttl)
end

-- Returns the seconds to wait if the username or the address is over its limit, else nil.
function M.blocked(username, ip)
    local cfg  = config.get()
    local dict = ngx.shared[DICT]
    local checks = {
        { user_key(username), cfg.auth_max_failures_user },
        { ip_key(ip),         cfg.auth_max_failures_ip },
    }
    for _, c in ipairs(checks) do
        local count = dict:get(c[1])
        if count and count >= c[2] then
            return retry_after(dict, c[1])
        end
    end
    return nil
end

-- Counts one failed CAS login. The window starts at the first failure and is not extended by later ones.
function M.record_failure(username, ip)
    local cfg  = config.get()
    local dict = ngx.shared[DICT]
    for _, key in ipairs({ user_key(username), ip_key(ip) }) do
        local _, err = dict:incr(key, 1, 0, cfg.auth_failure_window)
        if err then
            ngx.log(ngx.ERR, "failed-login counter: ", err)
        end
    end
end

-- A successful login clears the username's failures (not the address's: one address may try many users).
function M.reset_user(username)
    ngx.shared[DICT]:delete(user_key(username))
end

return M
