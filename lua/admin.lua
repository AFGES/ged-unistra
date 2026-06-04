local M = {}
local cjson = require("cjson")
local cache = require("cache")
local config = require("config")

function M.health()
    ngx.header["Content-Type"] = "application/json"
    -- Liveness: init_by_lua ran (config populated) and shared dict is reachable.
    -- No backend probe.
    local ok = config.get().webdav_base_url ~= nil
        and ngx.shared.cas_session_cache ~= nil
    if not ok then
        ngx.status = 503
        ngx.say(cjson.encode({ status = "unhealthy" }))
        return
    end
    ngx.say(cjson.encode({ status = "ok" }))
end

function M.cache_stats()
    ngx.header["Content-Type"] = "application/json"
    ngx.say(cjson.encode(cache.stats()))
end

function M.cache_clear()
    if ngx.req.get_method() ~= "DELETE" then
        ngx.status = 405
        ngx.header["Allow"] = "DELETE"
        ngx.header["Content-Type"] = "application/json"
        ngx.say(cjson.encode({ error = "Method Not Allowed" }))
        return
    end
    cache.flush()
    ngx.header["Content-Type"] = "application/json"
    ngx.say(cjson.encode({ message = "cache cleared" }))
end

return M
