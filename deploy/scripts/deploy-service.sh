#!/usr/bin/env bash
# R2-6 · Despliega una versión en la VM de UN microservicio, una réplica a la vez.
# La VM corre dos réplicas (<servicio>-a y <servicio>-b): se actualiza la "a", se espera su readiness y
# solo entonces la "b" (la otra sigue atendiendo detrás del NGINX del borde). Si una réplica nueva no
# queda lista, se vuelve a la versión anterior y el script termina con error para que el pipeline falle.
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

ready() {  # ready <puerto>
  local start; start=$(date +%s)
  while [ $(( $(date +%s) - start )) -lt "$timeout" ]; do
    if curl -fsS --max-time 3 "http://${private_ip}:$1/actuator/health/readiness" 2>/dev/null | grep -q '"UP"'; then
      echo "$(uname -n) · $service:$1 listo en $(( $(date +%s) - start )) s"; return 0
    fi
    sleep 3
  done
  return 1
}

rollback() {
  echo "$(uname -n) · $service NO quedó listo en ${timeout} s: vuelvo a ${previous:-la versión anterior}" >&2
  docker compose logs --tail 80 "$1" >&2 || true
  if [ -n "$previous" ]; then
    set_tag "$previous"
    docker compose up -d
    ready "$port" || echo "ATENCIÓN: la versión anterior tampoco quedó lista" >&2
  fi
  exit 1
}

echo "$(uname -n) · $service: ${previous:-?} → $tag"
set_tag "$tag"
[ "${SKIP_PULL:-0}" = 1 ] || docker compose pull   # SKIP_PULL=1 solo para ensayar con imágenes locales
docker compose up -d --no-deps "$service-a"            # la réplica b sigue con la versión anterior
ready "$port" || rollback "$service-a"
docker compose up -d --no-deps "$service-b"
ready "$((port + 10))" || rollback "$service-b"
docker image prune -f > /dev/null
echo "$(uname -n) · $service desplegado en $tag (2 réplicas)"
