#!/usr/bin/env bash
# R2-6 · Despliega una versión en ESTA VM (principal o respaldo) de un microservicio y espera su readiness.
# El pipeline lo ejecuta primero en la VM 1 y, solo si terminó bien, en la VM 2: mientras una se actualiza,
# la otra atiende detrás del balanceador del borde. Si la versión nueva no queda lista, vuelve a la anterior y
# termina con error para que el pipeline aborte antes de tocar la otra VM.
#
#   deploy-service.sh <wellbeing|marketplace|realtime> <tag>
#
# Requiere en la VM: /opt/zeal/docker-compose.yml (deploy/nodes/<servicio>/) y /opt/zeal/.env.
set -euo pipefail

service="${1:?Uso: deploy-service.sh <wellbeing|marketplace|realtime> <tag>}"
tag="${2:?Falta el tag de la imagen (SHA del commit)}"
dir="${ZEAL_DIR:-/opt/zeal}"
timeout="${READINESS_TIMEOUT:-180}"

case "$service" in
  wellbeing) port=8081 ;;
  marketplace) port=8082 ;;
  realtime) port=8083 ;;
  *) echo "Servicio desconocido: $service" >&2; exit 2 ;;
esac
[[ "$tag" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "Tag inválido: $tag" >&2; exit 2; }

cd "$dir"
private_ip="$(grep -E '^PRIVATE_IP=' .env | cut -d= -f2)"
previous="$(grep -E '^IMAGE_TAG=' .env | cut -d= -f2 || true)"

set_tag() {
  if grep -qE '^IMAGE_TAG=' .env; then sed -i "s/^IMAGE_TAG=.*/IMAGE_TAG=$1/" .env; else echo "IMAGE_TAG=$1" >> .env; fi
}

ready() {
  local start; start=$(date +%s)
  while [ $(( $(date +%s) - start )) -lt "$timeout" ]; do
    if curl -fsS --max-time 3 "http://${private_ip}:${port}/actuator/health/readiness" 2>/dev/null | grep -q '"UP"'; then
      echo "$(uname -n) · $service listo en $(( $(date +%s) - start )) s"; return 0
    fi
    sleep 3
  done
  return 1
}

echo "$(uname -n) · $service: ${previous:-?} → $tag"
set_tag "$tag"
[ "${SKIP_PULL:-0}" = 1 ] || docker compose pull   # SKIP_PULL=1 solo para ensayar con imágenes locales
docker compose up -d "$service"
if ready; then
  docker image prune -f > /dev/null
  echo "$(uname -n) · $service desplegado en $tag"
  exit 0
fi

echo "$(uname -n) · $service NO quedó listo en ${timeout} s: vuelvo a ${previous:-la versión anterior}" >&2
docker compose logs --tail 80 "$service" >&2 || true
if [ -n "$previous" ]; then
  set_tag "$previous"
  docker compose up -d "$service"
  ready || echo "ATENCIÓN: la versión anterior tampoco quedó lista" >&2
fi
exit 1
