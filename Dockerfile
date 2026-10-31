FROM docker.io/openresty/openresty:alpine-fat@sha256:2f1d99e7ed07740450013b52102842c366f1ef958e94811454cc5bca7ed98d38 AS builder
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
RUN luacheck lua/ tests/ && resty -I lua tests/totp_test.lua

FROM docker.io/openresty/openresty:alpine@sha256:2cb90d64192934c26b3749cf744f47edd59277787fe761bd109eeebdc3e2214a

LABEL maintainer="Charles LESECQ <charles.lesecq@afges.org>"
LABEL description="GED Unistra with CAS authentication and OpenResty as reverse proxy"

RUN apk add --no-cache ca-certificates

COPY nginx/nginx.conf /etc/nginx/conf.d/default.conf
COPY lua/ /etc/nginx/lua/
COPY --from=builder /usr/local/openresty/site/lualib/ /usr/local/openresty/site/lualib/

EXPOSE 80

CMD ["/usr/local/openresty/bin/openresty", "-g", "daemon off;"]
