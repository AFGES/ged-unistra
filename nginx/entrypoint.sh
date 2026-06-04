#!/bin/sh
set -e

# Extract first nameserver from /etc/resolv.conf and write resolver.conf
RESOLVER=$(awk '/^nameserver/{print $2; exit}' /etc/resolv.conf)
RESOLVER=${RESOLVER:-8.8.8.8}

echo "resolver ${RESOLVER} valid=300s ipv6=off;" > /etc/nginx/resolver.conf

exec /usr/local/openresty/bin/openresty -g "daemon off;"
