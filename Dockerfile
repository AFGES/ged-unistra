FROM docker.io/openresty/openresty:alpine-fat@sha256:73176295d21def3dcf884fc97d98191a07e61d615d4a3f3117549b9eea151653 AS builder
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

FROM docker.io/openresty/openresty:alpine@sha256:67f5110f14e1f51038f0adc19505a01b6868588692d22e291ccb3dd1dfcbeb04

LABEL maintainer="Charles LESECQ <charles.lesecq@afges.org>"
LABEL description="GED Unistra with CAS authentication and OpenResty as reverse proxy"

RUN apk add --no-cache ca-certificates

COPY nginx/nginx.conf /etc/nginx/conf.d/default.conf
COPY lua/ /etc/nginx/lua/
COPY --from=builder /usr/local/openresty/site/lualib/ /usr/local/openresty/site/lualib/

# 80: WebDAV and /health. 8081: unauthenticated admin endpoints, never publish it
EXPOSE 80 8081

CMD ["/usr/local/openresty/bin/openresty", "-g", "daemon off;"]
