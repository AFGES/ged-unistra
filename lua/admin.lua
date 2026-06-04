local M = {}
local cjson = require("cjson")
local cache = require("cache")

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
