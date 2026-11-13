#!/usr/bin/env bash
# Ensayo de "apagar una máquina" (la prueba de la evaluación) SIN Azure: levanta el balanceador del nodo de
# borde (nginx.multinode.conf.template, el mismo del despliegue real) delante de las réplicas del entorno
# local, tratando la réplica 1 de cada servicio como "la VM 1" y la 2 como "la VM 2". Con carga constante:
#   1. a los 30 s se APAGA a la fuerza la VM 1 de wellbeing, marketplace y realtime (como `az vm deallocate`),
#   2. a los 60 s se vuelve a encender,
# y se mide: errores visibles, operaciones confirmadas perdidas y a quién atendió cada VM en cada tramo.
#
#   MODE=activo   (defecto) las dos VMs reciben tráfico (UPSTREAM_2_FLAG vacío)
#   MODE=backup   la VM 2 es un respaldo estricto y solo recibe tráfico cuando la 1 falla
#   ./tests/disp/vm-failover.sh
set -euo pipefail
# shellcheck source=lib.sh source-path=SCRIPTDIR
source "$(dirname "$0")/lib.sh"
MODE="${MODE:-activo}"; RATE="${RATE:-30}"; PORT="${EDGE_TEST_PORT:-18080}"
flag=""; [ "$MODE" = backup ] && flag="backup"
net="$(docker inspect -f '{{range $k, $v := .NetworkSettings.Networks}}{{$k}}{{end}}' zeal-postgres-wellbeing)"
ip() { docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$1"; }
# Se fijan al inicio: `compose ps` no lista los contenedores apagados y el orden cambiaría al apagar uno.
declare -A VM
for s in wellbeing marketplace realtime; do for n in 1 2; do VM[$s$n]="$(replica "$s" "$n")"; done; done
vm1() { echo "${VM[${1}1]}"; }
ip_of_replica() { ip "${VM[${1}${2}]}"; }

docker rm -f zeal-edge-failover > /dev/null 2>&1 || true
docker run -d --name zeal-edge-failover --network "$net" -p "$PORT:8080" \
  -e NGINX_ENVSUBST_OUTPUT_DIR=/etc/nginx -e UPSTREAM_2_FLAG="$flag" -e FRONTEND_PORT=80 \
  -e WELLBEING_1_HOST="$(ip_of_replica wellbeing 1)"     -e WELLBEING_2_HOST="$(ip_of_replica wellbeing 2)" \
  -e MARKETPLACE_1_HOST="$(ip_of_replica marketplace 1)" -e MARKETPLACE_2_HOST="$(ip_of_replica marketplace 2)" \
  -e REALTIME_1_HOST="$(ip_of_replica realtime 1)"       -e REALTIME_2_HOST="$(ip_of_replica realtime 2)" \
  -e FRONTEND_1_HOST="$(ip_of_replica wellbeing 1)"      -e FRONTEND_2_HOST="$(ip_of_replica wellbeing 2)" \
  -e LIVEKIT_HOST="$(ip zeal-livekit)" \
  -v "$COMPOSE_DIR/nginx/nginx.multinode.conf.template:/etc/nginx/templates/nginx.conf.template:ro" \
  -v "$COMPOSE_DIR/nginx/conf.d:/etc/nginx/conf.d:ro" nginx:1.27-alpine > /dev/null
trap 'docker rm -f zeal-edge-failover > /dev/null 2>&1 || true; for s in wellbeing marketplace realtime; do docker start "$(vm1 $s)" > /dev/null 2>&1 || true; done' EXIT
for _ in $(seq 1 20); do curl -fs "localhost:$PORT/gateway/health" > /dev/null 2>&1 && break; sleep 1; done
curl -fs "localhost:$PORT/gateway/health" > /dev/null || { echo "El balanceador no arrancó:"; docker logs zeal-edge-failover 2>&1 | tail -5; exit 1; }

echo "== Apagar una máquina · modo $MODE · $RATE req/s por el balanceador del borde (:$PORT)"
run_k6 disp-load.js failover-summary.json ZEAL_API="http://localhost:$PORT" RATE="$RATE" DURATION=90s \
  > "$OUT_DIR/failover-k6.log" 2>&1 &
k6_pid=$!
sleep 25
since_before="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
sleep 4
t_off="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "   $(date +%T) SE APAGA la VM 1 de wellbeing, marketplace y realtime"
for s in wellbeing marketplace realtime; do docker kill "$(vm1 $s)" > /dev/null; done
sleep 30
t_on="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "   $(date +%T) SE ENCIENDE de nuevo la VM 1 de cada servicio"
for s in wellbeing marketplace realtime; do docker start "$(vm1 $s)" > /dev/null; done
wait "$k6_pid" || true
docker logs zeal-edge-failover > "$OUT_DIR/failover-edge.log" 2>&1

share() {  # share <desde> <hasta> <ip-de-la-vm>: peticiones atendidas por esa VM en el tramo
  docker logs --since "$1" --until "$2" zeal-edge-failover 2>/dev/null | grep '^{' \
    | jq -r --arg ip "$3:" 'select(.upstream | startswith($ip)) | .status' | wc -l
}
S=failover-summary.json
errors="$(metric $S '.metrics.visible_errors.values.count // 0')"; failed="$(metric $S '.metrics.http_req_failed.values.rate')"
requests="$(metric $S '.metrics.http_reqs.values.count')"; p95="$(metric $S '.metrics.http_req_duration.values["p(95)"]')"
max="$(metric $S '.metrics.http_req_duration.values.max')"
project="$(metric $S '.setup_data.projectId')"; confirmed="$(metric $S '.metrics.confirmed_writes.values.count // 0')"
stored="$(docker exec zeal-postgres-marketplace psql -U zeal_user -d zeal_marketplace_db -tAc "select count(*) from marketplace.applications where project_id = '$project'")"
w1="$(ip_of_replica wellbeing 1)"; w2="$(ip_of_replica wellbeing 2)"
now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

printf '\n| Medida | Resultado | Objetivo |\n|---|---|---|\n'
printf '| Peticiones | %s | — |\n| Errores visibles | %s (%.3f %%) | 0 |\n' "$requests" "$errors" "$(echo "$failed * 100" | bc -l)"
printf '| p95 / máximo | %.0f ms / %.0f ms | (la primera petición tras apagar espera ~2 s) |\n' "$p95" "$max"
printf '| Postulaciones confirmadas / guardadas | %s / %s | iguales (0 perdidas) |\n' "$confirmed" "$stored"
printf '| wellbeing: VM 1 antes / apagada / VM 2 durante el apagado | %s / %s / %s peticiones |\n' \
  "$(share "$since_before" "$t_off" "$w1")" "$(share "$t_off" "$t_on" "$w1")" "$(share "$t_off" "$t_on" "$w2")"
printf '| wellbeing: VM 1 después de encenderla (entra sola) | %s peticiones | > 0 en modo activo |\n' "$(share "$t_on" "$now" "$w1")"

echo "Respuestas que no fueron 2xx/3xx/4xx esperadas (de $OUT_DIR/failover-edge.log):"
grep '^{' "$OUT_DIR/failover-edge.log" | jq -r 'select(.status >= 500) | "   \(.time) \(.method) \(.uri) → \(.status) upstream=\(.upstream) \(.requestTime)s"' | head -5
ok=1
[ "$errors" -eq 0 ] || ok=0
[ "$confirmed" -eq "$stored" ] || ok=0
[ "$requests" -gt 100 ] || ok=0
[ "$(share "$t_off" "$t_on" "$w2")" -gt 0 ] || ok=0
[ "$ok" -eq 1 ] && echo "RESULTADO: APROBADO" || { echo "RESULTADO: FALLIDO"; exit 1; }
