local M = {}
local _cfg = {}

function M.init()
    local webdav_base = os.getenv("WEBDAV_BASE_URL") or "https://ged.unistra.fr/nuxeo/site/dav"
    -- Strip trailing slash for consistent URL rewriting
    webdav_base = webdav_base:gsub("/$", "")

    _cfg = {
        cas_login_url  = os.getenv("CAS_LOGIN_URL")
            or "https://cas.unistra.fr/cas/login?service=https%3A%2F%2Fged.unistra.fr%2Fnuxeo%2Fnxstartup.faces",
        webdav_base_url = webdav_base,
        auth_cache_ttl  = tonumber(os.getenv("AUTH_CACHE_TTL")) or 3000,
        debug_mode      = os.getenv("DEBUG_MODE") == "true",
    }
end

function M.get()
    return _cfg
end

function M.debug(...)
    if _cfg.debug_mode then
        ngx.log(ngx.DEBUG, "[cas-proxy] ", ...)
    end
end

return M
