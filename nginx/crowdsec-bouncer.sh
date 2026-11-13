#!/bin/sh
# SEG-1 · "Bouncer" de CrowdSec para NGINX, sin módulos Lua: cada 5 s consulta las decisiones de bloqueo
# de la API local de CrowdSec y, solo si cambiaron, regenera /etc/nginx/crowdsec/banned.conf (una línea
# "<ip> 1;" por IP) y recarga NGINX. El mapa $crowdsec_banned (zeal-common.conf) lo lee.
# Se ejecuta como script de arranque de la imagen nginx; sin CROWDSEC_LAPI_URL no hace nada.
[ -n "$CROWDSEC_LAPI_URL" ] && [ -n "$CROWDSEC_BOUNCER_KEY" ] || exit 0
mkdir -p /etc/nginx/crowdsec
(
  last="-"
  while true; do
    sleep 5
    body="$(curl -fsS --max-time 4 -H "X-Api-Key: $CROWDSEC_BOUNCER_KEY" \
      "$CROWDSEC_LAPI_URL/v1/decisions?type=ban&scope=Ip" 2>/dev/null)" || continue
    ips="$(printf '%s' "$body" | grep -o '"value":"[^"]*"' | cut -d'"' -f4 | sort -u)"
    [ "$ips" = "$last" ] && continue
    { for ip in $ips; do echo "$ip 1;"; done; } > /etc/nginx/crowdsec/banned.conf.tmp \
      && mv /etc/nginx/crowdsec/banned.conf.tmp /etc/nginx/crowdsec/banned.conf \
      && nginx -s reload > /dev/null 2>&1 && last="$ips"
  done
) > /dev/null 2>&1 &
