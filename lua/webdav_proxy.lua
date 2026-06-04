local M = {}
local cas_auth = require("cas_auth")

local function parse_basic_auth(auth_header)
    if not auth_header then return nil, nil end
    local b64 = auth_header:match("^%s*[Bb]asic%s+(.+)$")
    if not b64 then return nil, nil end
    local decoded = ngx.decode_base64(b64)
    if not decoded then return nil, nil end
    -- Split on first colon only; password may contain colons
    local username, password = decoded:match("^([^:]+):(.+)$")
    return username, password
end

-- Escape a literal string for use in Lua string.gsub pattern
local function escape_pattern(s)
    return (s:gsub("([%.%+%-%*%?%[%]%^%$%(%)%%])", "%%%1"))
end

-- Lazily compiled rewrite pattern derived from WEBDAV_BASE_URL
local _rewrite_pattern

local function get_rewrite_pattern()
    if not _rewrite_pattern then
        local cfg = require("config").get()
        _rewrite_pattern = escape_pattern(cfg.webdav_base_url)
    end
    return _rewrite_pattern
end

-- access_by_lua_block: validate Basic Auth, run CAS auth, inject Cookie.
function M.authenticate()
    local auth_header = ngx.var.http_authorization
    if not auth_header then
        ngx.header["WWW-Authenticate"] = 'Basic realm="GED Unistra"'
        return ngx.exit(401)
    end

    local username, password = parse_basic_auth(auth_header)
    if not username then
        ngx.header["WWW-Authenticate"] = 'Basic realm="GED Unistra"'
        return ngx.exit(401)
    end

    local jsessionid, err = cas_auth.get_jsessionid(username, password)
    if not jsessionid then
        ngx.log(ngx.ERR, "CAS auth failed for ", username, ": ", err)
        ngx.header["WWW-Authenticate"] = 'Basic realm="GED Unistra"'
        return ngx.exit(401)
    end

    ngx.req.set_header("Cookie", "JSESSIONID=" .. jsessionid)
    ngx.req.clear_header("Authorization")
end

-- header_filter_by_lua_block: mark PROPFIND for body buffering,
-- disable response buffering for all other methods (streaming),
-- strip backend Set-Cookie from reaching the client.
function M.rewrite_response_headers()
    -- Never expose backend session cookies to WebDAV clients
    ngx.header["Set-Cookie"] = nil

    if ngx.req.get_method() == "PROPFIND" then
        ngx.ctx.is_propfind = true
        -- Clear Content-Length; nginx will use chunked TE after body rewrite
        ngx.header.content_length = nil
    else
        -- Disable buffering for GET/PUT/etc so files stream directly
        ngx.header["X-Accel-Buffering"] = "no"
    end
end

-- body_filter_by_lua_block: accumulate PROPFIND body and rewrite absolute URLs.
-- All other methods pass through unchanged.
function M.rewrite_propfind_body()
    if not ngx.ctx.is_propfind then return end

    local chunk = ngx.arg[1]
    local eof   = ngx.arg[2]

    if chunk and chunk ~= "" then
        ngx.ctx.resp_body = (ngx.ctx.resp_body or "") .. chunk
        ngx.arg[1] = ""
    end

    if eof then
        local body = ngx.ctx.resp_body or ""
        -- Replace "https://ged.unistra.fr/nuxeo/site/dav" → "" so that
        -- "/documents/foo.pdf" paths remain absolute from the proxy root.
        local rewritten = body:gsub(get_rewrite_pattern(), "")
        ngx.arg[1] = rewritten
    end
end

return M
