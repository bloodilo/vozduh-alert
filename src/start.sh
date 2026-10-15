#!/bin/sh
mkdir -p /etc/nginx/ssl
if [ -s /certs/fullchain.pem ] && [ -s /certs/privkey.pem ]; then
    ln -sf /certs/fullchain.pem /etc/nginx/ssl/fullchain.pem
    ln -sf /certs/privkey.pem /etc/nginx/ssl/privkey.pem
else
    echo "WARN: в /certs нет fullchain.pem+privkey.pem — временно самоподписанный;"
    echo "      положите настоящие и сделайте: docker exec vozduh-alert nginx -s reload"
    openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj "/CN=vozduh-alert" \
        -keyout /etc/nginx/ssl/privkey.pem -out /etc/nginx/ssl/fullchain.pem 2>/dev/null
fi
redis-server --save '' --appendonly no --daemonize yes
(while :; do python /app.py; sleep 2; done) &
(while :; do python /parser_loop.py; sleep 5; done) &
exec nginx -g 'daemon off;'
