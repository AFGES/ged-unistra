# GED Unistra — WebDAV CAS Proxy

**English** | [Français](README.fr.md)

A small [OpenResty](https://openresty.org/) (nginx + Lua) reverse proxy that
fronts the Unistra GED ([Nuxeo](https://www.nuxeo.com/)) WebDAV endpoint and
performs [CAS](https://www.unistra.fr/) authentication transparently on behalf
of WebDAV clients.

Standard WebDAV clients (GVFS, Windows Explorer, macOS Finder, davfs2, …) only
speak HTTP Basic Auth — they cannot follow a CAS login flow. This proxy accepts
Basic Auth, runs the CAS login on the user's behalf, caches the resulting
session, and forwards requests to the backend with the right cookie attached.

> This is a rewrite of an earlier Node.js implementation.

## What it does

```
WebDAV client ──Basic Auth──▶ proxy ──CAS login──▶ cas.unistra.fr
                                │
                                │  inject JSESSIONID cookie
                                ▼
                       ged.unistra.fr/nuxeo/site/dav/
```

1. The client sends an HTTP Basic `Authorization` header.
2. The proxy decodes the credentials and runs the full CAS login flow to obtain
   a Nuxeo `JSESSIONID`.
3. The `JSESSIONID` is cached, the `Authorization` header is dropped, and a
   `Cookie: JSESSIONID=…` is injected.
4. The request is proxied to `https://ged.unistra.fr/nuxeo/site/dav/`.

Backend `Set-Cookie` headers are stripped so session cookies are never exposed
to the WebDAV client.

## Architecture / request flow

The whole flow lives in [`nginx/nginx.conf`](nginx/nginx.conf) and the Lua
modules under [`lua/`](lua/):

| Phase | Module | Responsibility |
|-------|--------|----------------|
| `access_by_lua` | `webdav_proxy.authenticate` | Validate Basic Auth, run CAS, swap `Authorization` → `Cookie` (401 on failure) |
| `proxy_pass` | nginx | Forward to upstream `ged_backend` (`ged.unistra.fr:443`, keepalive 32) over verified TLS |
| `header_filter_by_lua` | `webdav_proxy.rewrite_response_headers` | Strip backend `Set-Cookie`; mark PROPFIND for body rewriting; disable buffering for other methods (streaming) |
| `body_filter_by_lua` | `webdav_proxy.rewrite_propfind_body` | Rewrite absolute backend URLs to root-relative; percent-decode `displayname` in PROPFIND XML |

**CAS flow** ([`lua/cas_auth.lua`](lua/cas_auth.lua)):
GET the login page → extract the `execution` token → POST credentials with
**no redirect following** → read `JSESSIONID` from `Set-Cookie` (following one
`302` if the cookie is not on the POST response). If CAS answers with its
second-factor page, the proxy POSTs a TOTP code (`token`, new `execution`,
`_eventId_submit=Login`) before reading `JSESSIONID`. Only one CAS login runs
per credentials at a time; parallel requests wait for its result.

**Session cache** ([`lua/cache.lua`](lua/cache.lua)): cache-first lookup in a
10 MB `lua_shared_dict`. Key is `cookies_<base64(username)>_<sha256hex(password)>`;
value is `jsessionid|base64(username)|timestamp`. Default TTL 3000 s (50 min),
LRU eviction when full.

## Endpoints

| Port | Method | Path | Description |
|------|--------|------|-------------|
| 80 | any | `/` | WebDAV proxy — requires Basic Auth |
| 80 | `GET` | `/health` | Liveness JSON (`{"status":"ok"}`), no backend probe |
| 8081 | `GET` | `/admin/cache/stats` | Shared-dict key count, capacity and free bytes |
| 8081 | `DELETE` | `/admin/cache/clear` | Flush the session cache (`405` on any other method) |

The admin endpoints have no authentication: they listen on port `8081` only. Never
publish that port; reach it from a private network or with `docker exec`.

## Configuration

All configuration is via environment variables (see [`.env.example`](.env.example)
and [`lua/config.lua`](lua/config.lua)):

| Variable | Default | Description |
|----------|---------|-------------|
| `CAS_LOGIN_URL` | `https://cas.unistra.fr/cas/login?service=…nxstartup.faces` | CAS login URL (with the Nuxeo service param) |
| `WEBDAV_BASE_URL` | `https://ged.unistra.fr/nuxeo/site/dav` | Backend WebDAV base; trailing slash is stripped. Used to rewrite absolute URLs in PROPFIND responses |
| `AUTH_CACHE_TTL` | `3000` | Session cache TTL in seconds |
| `AUTH_MAX_FAILURES_USER` | `5` | Failed CAS logins allowed per username within the window |
| `AUTH_MAX_FAILURES_IP` | `20` | Failed CAS logins allowed per client address within the window |
| `AUTH_FAILURE_WINDOW` | `900` | Window for the failed-login limits, in seconds |
| `DEBUG_MODE` | `false` | Enable `[cas-proxy]` debug logging |

## Run

### With Docker Compose

```bash
docker compose up --build
```

The proxy listens on container port `80`, mapped to host port `3000`
(see [`docker-compose.yml`](docker-compose.yml)). The container is capped at
64 MB / 0.5 CPU and runs with `no-new-privileges`.

### Prebuilt image (GHCR)

Images are built and pushed by CI
([`.github/workflows/build-container.yml`](.github/workflows/build-container.yml))
on every push to `main` and on `v*` tags:

```bash
docker pull ghcr.io/afges/ged-unistra:latest
docker run -p 3000:80 ghcr.io/afges/ged-unistra:latest
```

Tags published: branch name, `sha-<commit>`, semver (`x.y.z`, `x.y`) on tags,
and `latest` on the default branch.

## Usage

Mount the proxy with any WebDAV client using your Unistra credentials. Examples:

```bash
# GIO / GVFS
gio mount dav://user@localhost:3000/

# davfs2
sudo mount -t davfs http://localhost:3000/ /mnt/ged
```

### Two-factor authentication (2FA)

Unistra CAS can ask for a second factor. The proxy supports only the **TOTP**
method, and generates the codes itself:

1. Activate the TOTP method in the
   [Unistra 2FA manager](https://cas-mfa.app.unistra.fr/). It shows a QR code and
   a character string: the string is your TOTP secret.
2. Set your WebDAV password to `password||SECRET` (secret after the last `||`;
   spaces and case are ignored).

You can also give a current code instead of the secret: `password||123456`. The
code is used as is, so the session lasts only until the cache expires
(`AUTH_CACHE_TTL`); then a new code is needed.

Accounts without 2FA keep using the plain password. Push, email codes, code grid
and WebAuthn are not supported.

## Security notes

- **Use TLS in front of this proxy in production.** It listens on plain `:80`
  and accepts HTTP Basic Auth, so credentials travel in clear text unless TLS is
  terminated upstream (reverse proxy / ingress).
- Credentials are sent on every request. The password is never stored — only its
  SHA-256 appears in the cache key; only the derived `JSESSIONID` is cached.
- With 2FA, the proxy receives **both factors** (password and TOTP secret) on
  every request. Run it only for yourself or users who trust its operator, and
  only behind TLS. The secret is never stored or logged: it is hashed into the
  cache key with the password.
- **Failed-login limits.** Each login that CAS refuses (wrong password or second
  factor) counts against the username and the client address. Past
  `AUTH_MAX_FAILURES_USER` or `AUTH_MAX_FAILURES_IP` failures within
  `AUTH_FAILURE_WINDOW`, the proxy answers `429` with `Retry-After` and does not
  call CAS, so it cannot be used to guess passwords or lock Unistra accounts. A
  successful login clears the username's count. Requests with a cached session
  are never blocked, and CAS network errors do not count.
- The client address comes from `X-Forwarded-For`, trusted from private ranges
  (`10/8`, `172.16/12`, `192.168/16`, loopback). Run the proxy behind a reverse
  proxy that appends the client address; a client on a private network could
  otherwise choose its own.
- Backend `Set-Cookie` headers are never forwarded to the client.
- Upstream TLS is verified (`proxy_ssl_verify on`, system CA bundle).

## Project layout

```
.
├── nginx/nginx.conf          # routes, upstream, Lua hooks
├── lua/
│   ├── config.lua            # env-var config + defaults
│   ├── cas_auth.lua          # CAS login flow (+ TOTP second factor)
│   ├── limiter.lua           # failed-login limits per username and address
│   ├── totp.lua              # RFC 6238 TOTP code generator
│   ├── cache.lua             # shared-dict session cache
│   ├── webdav_proxy.lua      # auth + PROPFIND/header rewriting
│   └── admin.lua             # /health + cache admin endpoints
├── tests/totp_test.lua       # TOTP unit tests
├── Dockerfile                # OpenResty image; `--target test` runs luacheck + tests
├── docker-compose.yml
└── .github/workflows/
    ├── ci.yml                # lint, tests, smoke test, zizmor
    └── build-container.yml   # build and push to GHCR
```
