#!/usr/bin/env bash
# R2-6 · Despliega una versión en ESTA VM (principal o respaldo) de un microservicio y espera su readiness.
# El pipeline lo ejecuta primero en la VM 1 y, solo si terminó bien, en la VM 2: mientras una se actualiza,
# la otra atiende detrás del balanceador del borde. Si la versión nueva no queda lista, vuelve a la anterior y
# termina con error para que el pipeline aborte antes de tocar la otra VM.
#
#   deploy-service.sh <wellbeing|marketplace|realtime> <tag>
#
# Requiere en la VM: docker-compose.yml y .env en deploy/nodes/<servicio>/ (copiados a /opt/zeal), o en
# deploy/duo/app/ cuando la máquina corre varios servicios (despliegue en dos máquinas).
set -euo pipefail

service="${1:?Uso: deploy-service.sh <wellbeing|marketplace|realtime> <tag>}"
tag="${2:?Falta el tag de la imagen (SHA del commit)}"
# Carpeta con el docker-compose.yml y el .env de esta VM: la de dos máquinas (deploy/duo/app) si existe; si no, /opt/zeal.
dir="${ZEAL_DIR:-}"
if [ -z "$dir" ]; then
  dir=/opt/zeal
  [ -f /opt/zeal/zeal-infra-compose/deploy/duo/app/.env ] && dir=/opt/zeal/zeal-infra-compose/deploy/duo/app
fi
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
# Con un servicio por VM la etiqueta es IMAGE_TAG; cuando la VM corre varios servicios (deploy/duo) cada uno
# tiene la suya: WELLBEING_TAG, MARKETPLACE_TAG, REALTIME_TAG.
tag_var="IMAGE_TAG"
grep -qE "^${service^^}_TAG=" .env && tag_var="${service^^}_TAG"
previous="$(grep -E "^${tag_var}=" .env | cut -d= -f2 || true)"

set_tag() {
  if grep -qE "^${tag_var}=" .env; then sed -i "s/^${tag_var}=.*/${tag_var}=$1/" .env; else echo "${tag_var}=$1" >> .env; fi
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
