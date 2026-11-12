#!/usr/bin/env bash
# R2-6 · Despliega UNA réplica de un servicio en ESTE nodo de servicios y espera su readiness.
# Lo invoca el pipeline por SSH en services-1 y, solo si terminó bien, en services-2 (una réplica a la
# vez: la otra sigue atendiendo detrás de NGINX). Si la réplica nueva no queda lista, vuelve a la
# versión anterior y termina con error para que el pipeline aborte antes de tocar el otro nodo.
#
#   deploy-service.sh <wellbeing|marketplace|realtime> <tag>
#
# Requiere /opt/zeal/docker-compose.yml y /opt/zeal/.env (deploy/nodes/services) en el nodo.
set -euo pipefail

service="${1:?Uso: deploy-service.sh <wellbeing|marketplace|realtime> <tag>}"
tag="${2:?Falta el tag de la imagen (SHA del commit)}"
dir="${ZEAL_DIR:-/opt/zeal}"
timeout="${READINESS_TIMEOUT:-180}"

case "$service" in
  wellbeing) port=8081; var=WELLBEING_TAG ;;
  marketplace) port=8082; var=MARKETPLACE_TAG ;;
  realtime) port=8083; var=REALTIME_TAG ;;
  *) echo "Servicio desconocido: $service" >&2; exit 2 ;;
esac
[[ "$tag" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "Tag inválido: $tag" >&2; exit 2; }

cd "$dir"
private_ip="$(grep -E '^PRIVATE_IP=' .env | cut -d= -f2)"
previous="$(grep -E "^${var}=" .env | cut -d= -f2 || true)"

set_tag() {
  if grep -qE "^${var}=" .env; then sed -i "s/^${var}=.*/${var}=$1/" .env; else echo "${var}=$1" >> .env; fi
}

ready() {
  local start; start=$(date +%s)
  while [ $(( $(date +%s) - start )) -lt "$timeout" ]; do
    if curl -fsS --max-time 3 "http://${private_ip}:${port}/actuator/health/readiness" | grep -q '"UP"'; then
      echo "$(hostname) · $service listo en $(( $(date +%s) - start )) s"; return 0
    fi
    sleep 3
  done
  return 1
}

echo "$(hostname) · $service: ${previous:-?} → $tag"
set_tag "$tag"
docker compose pull "$service"
docker compose up -d --no-deps "$service"   # stop_grace_period + apagado ordenado de Spring
if ready; then
  docker image prune -f > /dev/null
  exit 0
fi

echo "$(hostname) · $service NO quedó listo en ${timeout} s: vuelvo a ${previous:-la versión anterior}" >&2
docker compose logs --tail 80 "$service" >&2 || true
if [ -n "$previous" ]; then
  set_tag "$previous"
  docker compose up -d --no-deps "$service"
  ready || echo "ATENCIÓN: la versión anterior tampoco quedó lista" >&2
fi
exit 1
