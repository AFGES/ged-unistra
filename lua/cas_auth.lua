local M = {}
local http   = require("resty.http")
local config = require("config")
local cache  = require("cache")

local CA_BUNDLE = "/etc/ssl/certs/ca-certificates.crt"
local USER_AGENT = "Mozilla/5.0 (compatible; WebDAV-CAS-Proxy)"

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

local function extract_jsessionid_from_url(url)
    return url:match(";jsessionid=([^?&;]+)")
end

local function normalize_set_cookie(v)
    if not v then return {} end
    if type(v) == "string" then return {v} end
    return v
end

-- Merge new Set-Cookie values into a cookie jar (name → value map)
local function merge_cookies(jar, set_cookie_list)
    for _, c in ipairs(set_cookie_list) do
        local pair = c:match("^([^;]+)")
        if pair then
            local name, value = pair:match("^([^=]+)=(.*)")
            if name then jar[name] = value end
        end
    end
end

local function jar_to_string(jar)
    local parts = {}
    for k, v in pairs(jar) do
        table.insert(parts, k .. "=" .. v)
    end
    return table.concat(parts, "; ")
end

-- Full CAS authentication flow.
-- Returns jsessionid, nil on success or nil, err on failure.
function M.authenticate(username, password)
    local cfg = config.get()
    local httpc = http.new()
    httpc:set_timeouts(5000, 10000, 15000)

    local ssl_opts = { ssl_verify = true, ssl_trusted_certificate = CA_BUNDLE }

    -- Step 1: GET CAS login page manually (no auto-redirect) so we accumulate
    -- ALL Set-Cookie headers from every hop — CAS needs those CSRF cookies.
    local jar = {}  -- cookie jar: name → value
    local html, final_url

    local url = cfg.cas_login_url
    for _ = 1, 5 do
        config.debug("CAS GET: ", url)
        local res, err = httpc:request_uri(url, {
            method        = "GET",
            headers       = {
                ["Cookie"]     = jar_to_string(jar),
                ["User-Agent"] = USER_AGENT,
            },
            ssl_verify    = ssl_opts.ssl_verify,
            ssl_trusted_certificate = ssl_opts.ssl_trusted_certificate,
            max_redirects = 0,
        })
        if not res then
            return nil, "CAS GET failed: " .. (err or "unknown")
        end

        config.debug("CAS GET status: ", res.status)
        merge_cookies(jar, normalize_set_cookie(res.headers["Set-Cookie"]))
        config.debug("CAS cookies after GET: ", jar_to_string(jar))

        if res.status == 200 then
            html = res.body
            final_url = url
            break
        elseif res.status >= 300 and res.status < 400 then
            local loc = res.headers["Location"]
            if not loc then
                return nil, "CAS GET redirect with no Location header"
            end
            -- Relative URL → absolute
            if loc:sub(1, 4) ~= "http" then
                loc = url:match("(https?://[^/]+)") .. loc
            end
            url = loc
        else
            return nil, "CAS GET unexpected status: " .. tostring(res.status)
        end
    end

    if not html then
        return nil, "CAS GET: too many redirects"
    end

    local execution = extract_execution(html)
    config.debug("execution token found: ", execution and "yes" or "no",
        " length: ", execution and #execution or 0)
    if not execution then
        return nil, "CAS execution token not found in login page"
    end

    -- Step 2: POST credentials with NO redirect following so we get the raw 302
    local form_body = ngx.encode_args({
        username    = username,
        password    = password,
        execution   = execution,
        _eventId    = "submit",
        geolocation = "",
    })

    config.debug("CAS POST for user: ", username, " cookies: ", jar_to_string(jar))
    local res2, err2 = httpc:request_uri(cfg.cas_login_url, {
        method  = "POST",
        body    = form_body,
        headers = {
            ["Content-Type"] = "application/x-www-form-urlencoded",
            ["Cookie"]       = jar_to_string(jar),
            ["Referer"]      = final_url,
            ["User-Agent"]   = USER_AGENT,
        },
        ssl_verify    = ssl_opts.ssl_verify,
        ssl_trusted_certificate = ssl_opts.ssl_trusted_certificate,
        max_redirects = 0,
    })
    if not res2 then
        return nil, "CAS POST failed: " .. (err2 or "unknown")
    end

    -- Classify the CAS response so we can tell "bad credentials" from
    -- "session/flow expired" (both render HTTP 401). Plain substring search
    -- (find with plain=true) — robust against markup/locale variation.
    local rbody = res2.body or ""
    local function has(s) return rbody:find(s, 1, true) ~= nil end
    local kind = "UNKNOWN"
    if has("attempt has failed") or has("Échec de la connexion")
        or has("Invalid credentials") then
        kind = "BAD_CREDENTIALS"
    elseif has("locate") or has("expired") or has("session") or has("flow") then
        kind = "SESSION/FLOW_LOST"
    end
    config.debug("CAS POST status: ", res2.status,
        " Location: ", res2.headers["Location"] or "none",
        " kind: ", kind)

    merge_cookies(jar, normalize_set_cookie(res2.headers["Set-Cookie"]))

    -- Check for JSESSIONID in POST Set-Cookie
    local jsessionid
    for _, c in ipairs(normalize_set_cookie(res2.headers["Set-Cookie"])) do
        local jid = extract_jsessionid_from_cookie(c)
        if jid then jsessionid = jid end
    end

    -- Check Location URL for ;jsessionid= (Nuxeo puts it here)
    if not jsessionid then
        local location = res2.headers["Location"] or ""
        jsessionid = extract_jsessionid_from_url(location)
        config.debug("JSESSIONID from Location URL: ", jsessionid or "not found")
    end

    -- If POST returned a redirect and JSESSIONID still not found, follow it
    if not jsessionid and res2.status >= 300 and res2.status < 400 then
        local location = res2.headers["Location"]
        if location then
            if location:sub(1, 4) ~= "http" then
                location = cfg.cas_login_url:match("(https?://[^/]+)") .. location
            end
            config.debug("Following POST redirect: ", location)

            local res3, err3 = httpc:request_uri(location, {
                method        = "GET",
                headers       = {
                    ["Cookie"]     = jar_to_string(jar),
                    ["User-Agent"] = USER_AGENT,
                },
                ssl_verify    = ssl_opts.ssl_verify,
                ssl_trusted_certificate = ssl_opts.ssl_trusted_certificate,
                max_redirects = 5,
            })
            if res3 then
                config.debug("redirect follow status: ", res3.status)
                for _, c in ipairs(normalize_set_cookie(res3.headers["Set-Cookie"])) do
                    local jid = extract_jsessionid_from_cookie(c)
                    if jid then jsessionid = jid end
                end
                if not jsessionid then
                    local fu = res3.headers["X-Resty-Final-URI"] or location
                    jsessionid = extract_jsessionid_from_url(fu)
                    config.debug("JSESSIONID from final URI: ", jsessionid or "not found")
                end
            else
                config.debug("redirect follow error: ", err3)
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
