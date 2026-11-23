FROM docker.io/openresty/openresty:alpine-fat@sha256:deec12e15d7601be31ffe18523a67b139456dceab3cf9a04a4017e07688906db AS builder
# Fetched from GitHub tags: OPM lags behind upstream releases
# renovate: datasource=github-tags depName=ledgetech/lua-resty-http
ARG LUA_RESTY_HTTP_VERSION=0.18.0
RUN curl -fsSL "https://github.com/ledgetech/lua-resty-http/archive/refs/tags/v${LUA_RESTY_HTTP_VERSION}.tar.gz" \
    | tar -xz -C /usr/local/openresty/site/lualib --strip-components=2 \
        "lua-resty-http-${LUA_RESTY_HTTP_VERSION}/lib/resty"

# Lint and unit tests: docker build --target test .
FROM builder AS test
RUN luarocks install luacheck 1.2.0-1
WORKDIR /src
COPY .luacheckrc ./
COPY lua/ lua/
COPY tests/ tests/
RUN luacheck lua/ tests/ \
    && resty -I lua tests/totp_test.lua \
    && resty --shdict 'cas_auth_state 1m' -I lua tests/limiter_test.lua \
    && resty -I lua tests/root_dates_test.lua

FROM docker.io/openresty/openresty:alpine@sha256:48b7a15d52d9ffc6b1198b206eb58c0d88b2d5059a08bf8393098df9a01c23e5

LABEL maintainer="Charles LESECQ <charles.lesecq@afges.org>"
LABEL description="GED Unistra with CAS authentication and OpenResty as reverse proxy"

RUN apk add --no-cache ca-certificates

COPY nginx/nginx.conf /etc/nginx/conf.d/default.conf
COPY lua/ /etc/nginx/lua/
COPY --from=builder /usr/local/openresty/site/lualib/ /usr/local/openresty/site/lualib/

# 80: WebDAV and /health. 8081: unauthenticated admin endpoints, never publish it
EXPOSE 80 8081

CMD ["/usr/local/openresty/bin/openresty", "-g", "daemon off;"]
