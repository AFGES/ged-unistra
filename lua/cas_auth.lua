local M             = {}
local http          = require("resty.http")
local config        = require("config")
local cache         = require("cache")

local CA_BUNDLE     = "/etc/ssl/certs/ca-certificates.crt"

local EXEC_PATTERNS = {
    'name=["\']execution["\'][^>]*value=["\']([^"\']+)["\']',
    'value=["\']([^"\']+)["\'][^>]*name=["\']execution["\']',
}

local function extract_execution(html)
    for _, pat in ipairs(EXEC_PATTERNS) do
        local v = html:match(pat)
        if v then return v end
    end
    return nil
end

local function extract_jsessionid_from_cookie(c)
    return c:match("[Jj][Ss][Ee][Ss][Ss][Ii][Oo][Nn][Ii][Dd]=([^;]+)")
end

local function normalize_set_cookie(v)
    if not v then return {} end
    if type(v) == "string" then return { v } end
    return v
end

-- Find a JSESSIONID across all Set-Cookie headers of a response.
local function jsessionid_from_set_cookie(headers)
    for _, c in ipairs(normalize_set_cookie(headers["Set-Cookie"])) do
        local jid = extract_jsessionid_from_cookie(c)
        if jid then return jid end
    end
    return nil
end

-- Full CAS authentication flow.
-- Returns jsessionid, nil on success or nil, err on failure.
function M.authenticate(username, password)
    local cfg = config.get()
    local httpc = http.new()
    httpc:set_timeouts(5000, 10000, 15000)

    local ssl_opts = { ssl_verify = true, ssl_trusted_certificate = CA_BUNDLE }

    -- Step 1: GET the CAS login page to obtain the execution token.
    -- The page is served directly (200, no redirect) and needs no cookies.
    local res, err = httpc:request_uri(cfg.cas_login_url, {
        method                  = "GET",
        ssl_verify              = ssl_opts.ssl_verify,
        ssl_trusted_certificate = ssl_opts.ssl_trusted_certificate,
    })
    if not res then
        return nil, "CAS GET failed: " .. (err or "unknown")
    end
    if res.status ~= 200 then
        return nil, "CAS GET unexpected status: " .. tostring(res.status)
    end

    local execution = extract_execution(res.body)
    if not execution then
        return nil, "CAS execution token not found in login page"
    end

    -- Step 2: POST credentials with NO redirect following so we get the raw 302.
    local form_body = ngx.encode_args({
        username    = username,
        password    = password,
        execution   = execution,
        _eventId    = "submit",
        geolocation = "",
    })

    local res2, err2 = httpc:request_uri(cfg.cas_login_url, {
        method                  = "POST",
        body                    = form_body,
        headers                 = { ["Content-Type"] = "application/x-www-form-urlencoded" },
        ssl_verify              = ssl_opts.ssl_verify,
        ssl_trusted_certificate = ssl_opts.ssl_trusted_certificate,
        max_redirects           = 0,
    })
    if not res2 then
        return nil, "CAS POST failed: " .. (err2 or "unknown")
    end

    -- Extract JSESSIONID: from the POST Set-Cookie
    local jsessionid = jsessionid_from_set_cookie(res2.headers)

    if not jsessionid and res2.status >= 300 and res2.status < 400 then
        local location = res2.headers["Location"]
        if location then
            if location:sub(1, 4) ~= "http" then
                location = cfg.cas_login_url:match("(https?://[^/]+)") .. location
            end
            local res3 = httpc:request_uri(location, {
                method                  = "GET",
                ssl_verify              = ssl_opts.ssl_verify,
                ssl_trusted_certificate = ssl_opts.ssl_trusted_certificate,
                max_redirects           = 5,
            })
            if res3 then
                jsessionid = jsessionid_from_set_cookie(res3.headers)
            end
        end
    end

    httpc:close()

    if not jsessionid then
        return nil, "JSESSIONID not found after CAS authentication (POST status "
            .. tostring(res2.status) .. ")"
    end

    return jsessionid, nil
end

-- Cache-first: check cache, fall through to full CAS auth on miss.
function M.get_jsessionid(username, password)
    local key = cache.make_key(username, password)
    local cfg = config.get()

    local cached = cache.get(key)
    if cached then
        config.debug("cache hit for: ", username)
        return cached, nil
    end

    config.debug("cache miss, authenticating: ", username)
    local jsessionid, err = M.authenticate(username, password)
    if not jsessionid then
        return nil, err
    end

    cache.set(key, jsessionid, username, cfg.auth_cache_ttl)
    ngx.log(ngx.INFO, "authenticated and cached: ", username)

    return jsessionid, nil
end

return M
