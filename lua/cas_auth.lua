local M             = {}
local http          = require("resty.http")
local config        = require("config")
local cache         = require("cache")
local totp          = require("totp")
local resty_lock    = require("resty.lock")

local CA_BUNDLE     = "/etc/ssl/certs/ca-certificates.crt"

-- Shared dict for login locks, recent failures and used TOTP steps.
local STATE_DICT    = "cas_auth_state"

-- Hidden field only present on the CAS second-factor page (the password page
-- uses "_eventId" instead).
local MFA_MARKER    = 'name=["\']_eventId_submit["\']'

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

-- POST a form to CAS with NO redirect following so we get the raw 302.
local function post_form(httpc, url, args, ssl_opts)
    return httpc:request_uri(url, {
        method                  = "POST",
        body                    = ngx.encode_args(args),
        headers                 = { ["Content-Type"] = "application/x-www-form-urlencoded" },
        ssl_verify              = ssl_opts.ssl_verify,
        ssl_trusted_certificate = ssl_opts.ssl_trusted_certificate,
        max_redirects           = 0,
    })
end

local function is_mfa_page(res)
    return res.status == 200 and res.body ~= nil
        and res.body:find(MFA_MARKER) ~= nil
end

-- TOTP code for a secret that CAS has not seen yet. CAS refuses a code it
-- already accepted or rejected, so if this secret was used in the current
-- 30 s step, wait for the next one.
local function fresh_totp_code(secret)
    local dict = ngx.shared[STATE_DICT]
    local mark = "totp_" .. ngx.encode_base64(ngx.sha1_bin(secret))
    ngx.update_time()
    local step = math.floor(ngx.now() / 30)
    if dict:get(mark) == step then
        ngx.sleep((step + 1) * 30 - ngx.now() + 0.5)
        step = step + 1
    end
    dict:set(mark, step, 90)
    return totp.code(secret, step * 30)
end

-- Full CAS authentication flow. second_factor is optional: { code = "123456" }
-- used as is, or { secret = "BASE32" }. It is only used when CAS asks for it.
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

    -- Step 2: POST credentials.
    local res2, err2 = post_form(httpc, cfg.cas_login_url, {
        username    = username,
        password    = password,
        execution   = execution,
        _eventId    = "submit",
        geolocation = "",
    }, ssl_opts)
    if not res2 then
        return nil, "CAS POST failed: " .. (err2 or "unknown")
    end

    -- Step 3 (only when CAS asks for a second factor): POST a TOTP code.
    if is_mfa_page(res2) then
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

        local code, cerr = second_factor.code, nil
        if not code then
            code, cerr = fresh_totp_code(second_factor.secret)
        end
        if not code then
            httpc:close()
            return nil, cerr
        end

        local err4
        res2, err4 = post_form(httpc, cfg.cas_login_url, {
            token           = code,
            execution       = mfa_execution,
            _eventId_submit = "Login",
        }, ssl_opts)
        if not res2 then
            httpc:close()
            return nil, "CAS MFA POST failed: " .. (err4 or "unknown")
        end
        -- No retry: a second attempt would reuse the same code.
        if is_mfa_page(res2) then
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

-- Lock lifetime must exceed a worst-case login: 4 CAS/backend requests with
-- 5+10+15 s timeouts each, plus up to 30 s waiting for a fresh TOTP step.
local LOCK_TTL      = 150
local LOCK_WAIT     = 60
-- A failed login is shared with waiters for this long, so they do not all
-- retry it (each retry counts toward CAS lockout).
local FAIL_TTL      = 5

-- Cache-first: check cache, fall through to full CAS auth on miss.
-- Only one CAS login runs per credentials at a time: WebDAV clients send
-- parallel requests, and a TOTP code must not be submitted twice.
function M.get_jsessionid(username, password, second_factor)
    -- Without a second factor the key is unchanged from earlier versions.
    local factor = second_factor and (second_factor.code or second_factor.secret)
    local key = cache.make_key(username,
        factor and (password .. "||" .. factor) or password)
    local cfg = config.get()

    local cached = cache.get(key)
    if cached then
        config.debug("cache hit for: ", username)
        return cached, nil
    end

    local lock, lerr = resty_lock:new(STATE_DICT, { exptime = LOCK_TTL, timeout = LOCK_WAIT })
    if not lock then
        return nil, "lock init failed: " .. (lerr or "unknown")
    end
    local elapsed, werr = lock:lock(key)
    if not elapsed then
        return nil, "waiting for concurrent CAS login failed: " .. (werr or "unknown")
    end

    -- Another request may have finished the login while we waited.
    cached = cache.get(key)
    if cached then
        lock:unlock()
        return cached, nil
    end
    local failed = ngx.shared[STATE_DICT]:get("fail_" .. key)
    if failed then
        lock:unlock()
        return nil, "concurrent CAS login failed: " .. failed
    end

    config.debug("cache miss, authenticating: ", username)
    local ok, jsessionid, err = pcall(M.authenticate, username, password, second_factor)
    if not ok then
        jsessionid, err = nil, "CAS login error: " .. tostring(jsessionid)
    end
    if jsessionid then
        cache.set(key, jsessionid, username, cfg.auth_cache_ttl)
        ngx.log(ngx.INFO, "authenticated and cached: ", username)
    else
        ngx.shared[STATE_DICT]:set("fail_" .. key, err or "unknown", FAIL_TTL)
    end
    lock:unlock()

    return jsessionid, err
end

return M
