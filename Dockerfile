FROM docker.io/openresty/openresty:alpine-fat AS builder
RUN opm get ledgetech/lua-resty-http=0.17.1

# Lint and unit tests: docker build --target test .
FROM builder AS test
RUN luarocks install luacheck 1.2.0-1
WORKDIR /src
COPY .luacheckrc ./
COPY lua/ lua/
COPY tests/ tests/
RUN luacheck lua/ tests/ && resty -I lua tests/totp_test.lua

FROM docker.io/openresty/openresty:alpine

LABEL maintainer="Charles LESECQ <charles.lesecq@afges.org>"
LABEL description="GED Unistra with CAS authentication and OpenResty as reverse proxy"

RUN apk add --no-cache ca-certificates

COPY nginx/nginx.conf /etc/nginx/conf.d/default.conf
COPY lua/ /etc/nginx/lua/
COPY --from=builder /usr/local/openresty/site/lualib/ /usr/local/openresty/site/lualib/

EXPOSE 80

CMD ["/usr/local/openresty/bin/openresty", "-g", "daemon off;"]
