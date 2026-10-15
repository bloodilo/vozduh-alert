#!/bin/sh
# Собирает релизный однофайловый Dockerfile из src/ — его и везём на VPS.
# Запуск: sh assemble.sh
set -e
cd "$(dirname "$0")"
{
  cat src/dockerfile-head
  cat src/index.html
  printf "HTMLEOF\n\nCOPY <<'NGEOF' /etc/nginx/http.d/default.conf\n"
  cat src/nginx.conf
  printf "NGEOF\n\nCOPY <<'APPEOF' /app.py\n"
  cat src/app.py
  printf "APPEOF\n\nCOPY <<'PARSEOF' /parser_loop.py\n"
  cat src/parser_loop.py
  printf "PARSEOF\n\nCOPY <<'SHEOF' /start.sh\n"
  cat src/start.sh
  printf "SHEOF\nRUN chmod +x /start.sh\n\nVOLUME /data\nEXPOSE 80 443\nHEALTHCHECK --interval=60s --timeout=5s --start-period=30s CMD wget -qO- http://127.0.0.1/healthz || exit 1\nCMD [\"/start.sh\"]\n"
} > Dockerfile
echo "Dockerfile собран: $(wc -l < Dockerfile) строк"
