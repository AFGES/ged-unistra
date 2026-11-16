-- Real dates for the top-level folders in the root listing.
--
-- In PROPFIND / (Depth 1), Nuxeo gives every top-level folder the request
-- time as getlastmodified and creationdate. The same folder queried on its
-- own (PROPFIND /cfvu/, Depth 0) has its real dates. Clients such as
-- "rclone sync" copy the root listing's dates, so every top-level folder got
-- the current date. The proxy serves the root listing itself, with each
-- top-level folder's dates taken from its own PROPFIND (cached).
local M      = {}
local http   = require("resty.http")
local config = require("config")

local CA_BUNDLE = "/etc/ssl/certs/ca-certificates.crt"
local DICT      = "dav_folder_dates"

-- Escape a literal string for use in a Lua pattern
local function escape_pattern(s)
    return (s:gsub("([%.%+%-%*%?%[%]%^%$%(%)%%])", "%%%1"))
end

-- Path of an href relative to the backend base URL ("" if outside it)
local function relative_path(href, base)
    local path = href:match("^" .. escape_pattern(base) .. "(.*)$")
    if path then return path end
    -- Hrefs may also be absolute paths ("/nuxeo/site/dav/cfvu")
    local base_path = base:match("^https?://[^/]+(/.*)$") or ""
    return href:match("^" .. escape_pattern(base_path) .. "(/.*)$") or ""
end

-- Top-level folder name of an href ("cfvu" for ".../dav/cfvu" or ".../dav/cfvu/"), or nil
local function top_level_name(href, base)
    return relative_path(href, base):match("^/([^/]+)/?$")
end

-- Names of the top-level folders listed in a root PROPFIND body
function M._child_hrefs(body, base)
    local names, seen = {}, {}
    for href in body:gmatch("<%w*:?href>(.-)</%w*:?href>") do
        local name = top_level_name(href, base)
        if name and not seen[name] then
            seen[name] = true
            names[#names + 1] = name
        end
    end
    return names
end

-- First getlastmodified and creationdate of a PROPFIND body
local function extract_dates(body)
    local lm = body:match("<%w*:?getlastmodified>(.-)</%w*:?getlastmodified>")
    local cd = body:match("<%w*:?creationdate>(.-)</%w*:?creationdate>")
    return lm, cd
end

-- Replace getlastmodified and creationdate of the top-level folders named in
-- dates ({ name = { lm = ..., cd = ... } }). Other responses are unchanged.
function M._apply_dates(body, dates, base)
    return (body:gsub("(<%w*:?response>)(.-)(</%w*:?response>)", function(open, inner, close)
        local href = inner:match("<%w*:?href>(.-)</%w*:?href>")
        local d = href and dates[top_level_name(href, base) or ""]
        if not d then return nil end
        if d.lm then
            inner = inner:gsub("(<%w*:?getlastmodified>).-(</%w*:?getlastmodified>)",
                function(o, c) return o .. d.lm .. c end)
        end
        if d.cd then
            inner = inner:gsub("(<%w*:?creationdate>).-(</%w*:?creationdate>)",
                function(o, c) return o .. d.cd .. c end)
        end
        return open .. inner .. close
    end))
end

local function propfind(url, depth, body, content_type)
    local httpc = http.new()
    httpc:set_timeouts(5000, 10000, 30000)
    local res, err = httpc:request_uri(url, {
        method                  = "PROPFIND",
        body                    = body,
        headers                 = {
            ["Depth"]        = depth,
            ["Content-Type"] = body and (content_type or "application/xml") or nil,
            ["Cookie"]       = ngx.var.http_cookie,
        },
        ssl_verify              = true,
        ssl_trusted_certificate = CA_BUNDLE,
    })
    if not res then return nil, err end
    if res.status ~= 207 then return nil, "status " .. res.status end
    return res.body
end

-- Real dates of one top-level folder, from the cache or its own PROPFIND
local function folder_dates(name, base, ttl)
    local dict = ngx.shared[DICT]
    local cached = dict:get(name)
    if cached then
        local lm, cd = cached:match("^(.-)\n(.*)$")
        return { lm = lm ~= "" and lm or nil, cd = cd ~= "" and cd or nil }
    end

    local body, err = propfind(base .. "/" .. name .. "/", "0")
    if not body then
        ngx.log(ngx.WARN, "dates of top-level folder ", name, " unavailable: ", err)
        return nil
    end
    local lm, cd = extract_dates(body)
    if not lm and not cd then return nil end
    local ok, set_err = dict:set(name, (lm or "") .. "\n" .. (cd or ""), ttl)
    if not ok then
        ngx.log(ngx.WARN, "cannot cache dates of ", name, ": ", set_err)
    end
    return { lm = lm, cd = cd }
end

-- access_by_lua_block, after authenticate(): serve PROPFIND / (Depth 1) with
-- the real dates of the top-level folders. Any other request, or a backend
-- error, falls through to proxy_pass.
function M.serve_root()
    if ngx.req.get_method() ~= "PROPFIND" or ngx.var.uri ~= "/" then return end
    local depth = ngx.var.http_depth or "infinity"
    if depth == "0" then return end

    local cfg  = config.get()
    local base = cfg.webdav_base_url

    ngx.req.read_body()
    local req_body = ngx.req.get_body_data()
    if not req_body and ngx.req.get_body_file() then return end
    local body, err = propfind(base .. "/", depth, req_body, ngx.var.http_content_type)
    if not body then
        ngx.log(ngx.WARN, "root listing for folder dates failed, proxying as is: ", err)
        return
    end

    local names = M._child_hrefs(body, base)
    local threads = {}
    for i, name in ipairs(names) do
        threads[i] = ngx.thread.spawn(folder_dates, name, base, cfg.folder_dates_ttl)
    end
    local dates = {}
    for i, name in ipairs(names) do
        local ok, d = ngx.thread.wait(threads[i])
        if ok and d then dates[name] = d end
    end

    ngx.status = 207
    ngx.header["Content-Type"] = "application/xml; charset=utf-8"
    ngx.print(M._apply_dates(body, dates, base))
    return ngx.exit(ngx.HTTP_OK)
end

return M
