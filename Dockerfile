FROM docker.io/openresty/openresty:alpine

LABEL maintainer="Charles Lesecq"
LABEL description="WebDAV CAS Proxy - OpenResty"

RUN apk add --no-cache ca-certificates

COPY nginx/nginx.conf /etc/nginx/conf.d/default.conf
COPY nginx/entrypoint.sh /entrypoint.sh
COPY lua/ /etc/nginx/lua/
COPY vendor/ /usr/local/openresty/site/lualib/

RUN chmod +x /entrypoint.sh

EXPOSE 80

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD wget -qO- http://localhost/admin/cache/stats || exit 1

ENTRYPOINT ["/entrypoint.sh"]
