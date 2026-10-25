local M             = {}
local http          = require("resty.http")
local config        = require("config")
local cache         = require("cache")
local totp          = require("totp")

local CA_BUNDLE     = "/etc/ssl/certs/ca-certificates.crt"

-- Hidden field only present on the CAS second-factor page (the password page
-- uses "_eventId" instead).
local MFA_MARKER    = 'name="_eventId_submit"'

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

-- Read JSESSIONID from a CAS response, following one 302 (service ticket
-- redirect to the backend) if the cookie is not on the response itself.
local function follow_for_jsessionid(httpc, res, cfg, ssl_opts)
    local jsessionid = jsessionid_from_set_cookie(res.headers)

    if not jsessionid and res.status >= 300 and res.status < 400 then
        local location = res.headers["Location"]
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

    return jsessionid
end

-- Full CAS authentication flow. second_factor is optional: a 6-digit TOTP code
-- used as is, or a base32 TOTP secret. It is only used when CAS asks for it.
-- Returns jsessionid, nil on success or nil, err on failure.
function M.authenticate(username, password, second_factor)
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

    -- Step 3 (only when CAS asks for a second factor): POST a TOTP code.
    if res2.status == 200 and res2.body and res2.body:find(MFA_MARKER, 1, true) then
        if not second_factor then
            httpc:close()
            return nil, "MFA required but no TOTP code or secret supplied"
        end
        config.debug("MFA required, submitting TOTP for: ", username)

        local mfa_execution = extract_execution(res2.body)
        if not mfa_execution then
            httpc:close()
            return nil, "CAS execution token not found in MFA page"
        end

        local code, cerr = second_factor, nil
        if not totp.is_code(code) then
            code, cerr = totp.code(second_factor, ngx.time())
        end
        if not code then
            httpc:close()
            return nil, cerr
        end

        local err4
        res2, err4 = httpc:request_uri(cfg.cas_login_url, {
            method                  = "POST",
            body                    = ngx.encode_args({
                token           = code,
                execution       = mfa_execution,
                _eventId_submit = "Login",
            }),
            headers                 = { ["Content-Type"] = "application/x-www-form-urlencoded" },
            ssl_verify              = ssl_opts.ssl_verify,
            ssl_trusted_certificate = ssl_opts.ssl_trusted_certificate,
            max_redirects           = 0,
        })
        if not res2 then
            httpc:close()
            return nil, "CAS MFA POST failed: " .. (err4 or "unknown")
        end
        -- No retry: a second attempt would reuse the same code.
        if res2.status == 200 and res2.body and res2.body:find(MFA_MARKER, 1, true) then
            httpc:close()
            return nil, "TOTP code rejected"
        end
    end

    local jsessionid = follow_for_jsessionid(httpc, res2, cfg, ssl_opts)

    httpc:close()

    if not jsessionid then
        return nil, "JSESSIONID not found after CAS authentication (POST status "
            .. tostring(res2.status) .. ")"
    end

    return jsessionid, nil
end

-- Seconds a login may hold the per-user lock, and how long others wait for it.
local LOCK_TTL      = 30
local LOCK_WAIT     = 20
local LOCK_POLL     = 0.2

-- Cache-first: check cache, fall through to full CAS auth on miss.
-- Only one CAS login runs per credentials at a time: WebDAV clients send
-- parallel requests, and a TOTP code must not be submitted twice.
function M.get_jsessionid(username, password, second_factor)
    -- Without a secret the key is unchanged from earlier versions.
    local key = cache.make_key(username,
        second_factor and (password .. "|" .. second_factor) or password)
    local cfg = config.get()

    local cached = cache.get(key)
    if cached then
        config.debug("cache hit for: ", username)
        return cached, nil
    end

    if not cache.lock(key, LOCK_TTL) then
        config.debug("login in progress, waiting: ", username)
        local waited = 0
        while waited < LOCK_WAIT do
            ngx.sleep(LOCK_POLL)
            waited = waited + LOCK_POLL
            cached = cache.get(key)
            if cached then
                return cached, nil
            end
            -- Lock released without a cached session: that login failed.
            if not cache.is_locked(key) then
                return nil, "concurrent CAS login failed"
            end
        end
        return nil, "timed out waiting for concurrent CAS login"
    end

    config.debug("cache miss, authenticating: ", username)
    local jsessionid, err = M.authenticate(username, password, second_factor)
    if jsessionid then
        cache.set(key, jsessionid, username, cfg.auth_cache_ttl)
        ngx.log(ngx.INFO, "authenticated and cached: ", username)
    end
    cache.unlock(key)

    return jsessionid, err
end

return M
