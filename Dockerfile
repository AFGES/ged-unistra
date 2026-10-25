FROM docker.io/openresty/openresty:alpine-fat@sha256:1f6f2542b0ee2a9874a57927211ce272322a850adb7fcc7432bd6af44184f6e0 AS builder
RUN opm get ledgetech/lua-resty-http=0.17.1

# Lint and unit tests: docker build --target test .
FROM builder AS test
RUN luarocks install luacheck 1.2.0-1
WORKDIR /src
COPY .luacheckrc ./
COPY lua/ lua/
COPY tests/ tests/
RUN luacheck lua/ tests/ && resty -I lua tests/totp_test.lua

FROM docker.io/openresty/openresty:alpine@sha256:8e223fc9644c0b12de445165ecc6161786d9f6aa1064ea5e77c9c88ba5d494b6

LABEL maintainer="Charles LESECQ <charles.lesecq@afges.org>"
LABEL description="GED Unistra with CAS authentication and OpenResty as reverse proxy"

RUN apk add --no-cache ca-certificates

COPY nginx/nginx.conf /etc/nginx/conf.d/default.conf
COPY lua/ /etc/nginx/lua/
COPY --from=builder /usr/local/openresty/site/lualib/ /usr/local/openresty/site/lualib/

EXPOSE 80

CMD ["/usr/local/openresty/bin/openresty", "-g", "daemon off;"]
