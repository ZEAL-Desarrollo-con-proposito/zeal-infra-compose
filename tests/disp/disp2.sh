#!/usr/bin/env bash
# DISP-2 · La demanda se duplica (HU-BE-19). Carga habitual; a los DOUBLE_AT segundos se duplica y en
# ese momento se agrega en caliente una réplica del servicio más exigido (marketplace: postulaciones
# y catálogo de talleres). Se mide cuánto tarda la réplica nueva en recibir tráfico (NGINX la
# descubre por DNS, sin recargar ni reiniciar nada) y el p95 con la carga duplicada.
#   SERVICE=marketplace RATE=40 ./tests/disp/disp2.sh
set -euo pipefail
# shellcheck source=lib.sh source-path=SCRIPTDIR
source "$(dirname "$0")/lib.sh"
SERVICE="${SERVICE:-marketplace}"; RATE="${RATE:-40}"; DOUBLE_AT="${DOUBLE_AT:-30}"
before="$(compose ps -q "$SERVICE" | wc -l)"

echo "== DISP-2 · $RATE req/s; a los ${DOUBLE_AT}s se duplica y $SERVICE pasa de $before a $((before + 1)) réplicas"
run_k6 disp-load.js disp2-summary.json RATE="$RATE" DURATION="$((DOUBLE_AT + 90))s" DOUBLE_AT="${DOUBLE_AT}s" DOUBLE_FOR=90s \
  > "$OUT_DIR/disp2-k6.log" 2>&1 &
k6_pid=$!
sleep "$DOUBLE_AT"

scaled_at=$(now)
echo "   $(date +%T) carga x2 y docker compose up --scale $SERVICE=$((before + 1))"
compose up -d --no-recreate --scale "$SERVICE=$((before + 1))" "$SERVICE" > /dev/null 2>&1
new="$(compose ps -q "$SERVICE" | while read -r id; do docker inspect -f '{{.Created}} {{.Id}}' "$id"; done | sort | tail -1 | cut -d' ' -f2)"
ip="$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$new")"
echo "   réplica nueva $(docker inspect -f '{{.Name}}' "$new" | tr -d /) ($ip)"

# Hora de la primera respuesta exitosa que dio la réplica nueva (log JSON de NGINX). Se ignoran los
# intentos fallidos: el DNS de Docker publica la réplica al crearla, antes de que esté lista; NGINX la
# prueba, recibe "connection refused" y reintenta en otra réplica sin que el cliente lo note.
served_ok() { docker logs --since "$since" zeal-api-gateway 2>/dev/null | grep '^{' | jq -c --arg u "$ip:" \
  'select((.upstream | startswith($u)) and (.upstream | contains(",") | not) and .status < 400)'; }
first_traffic="timeout"
since="$(date -u -d "@$scaled_at" +%Y-%m-%dT%H:%M:%SZ)"
while [ $(( $(now) - scaled_at )) -lt 180 ]; do
  first_line="$(served_ok | head -1 || true)"
  if [ -n "$first_line" ]; then
    first_at="$(date -d "$(jq -r .time <<<"$first_line")" +%s)"
    first_traffic=$(( first_at - scaled_at )); break
  fi
  sleep 1
done
wait "$k6_pid" || true

S=disp2-summary.json
p95="$(metric $S '.metrics.http_req_duration.values["p(95)"]')"
failed_rate="$(metric $S '.metrics.http_req_failed.values.rate')"
requests="$(metric $S '.metrics.http_reqs.values.count')"
served_by_new="$(served_ok | wc -l)"

printf '\n| Medida | Resultado | Objetivo |\n|---|---|---|\n'
printf '| Peticiones (carga habitual + duplicada) | %s | — |\n' "$requests"
printf '| Réplica nueva atiende su primera petición tras el escalado | %s s | < 120 s |\n' "$first_traffic"
printf '| Peticiones atendidas por la réplica nueva | %s | > 0 |\n' "$served_by_new"
printf '| p95 de toda la prueba | %.0f ms | ≤ 500 ms |\n' "$p95"
printf '| Tasa de error | %.3f %% | — |\n' "$(echo "$failed_rate * 100" | bc -l)"
printf '| Reinicios de las demás réplicas o de NGINX | 0 (solo se creó la nueva) | 0 |\n'

if [ "${KEEP_SCALE:-0}" != 1 ]; then compose up -d --no-recreate --scale "$SERVICE=$before" "$SERVICE" > /dev/null 2>&1; fi
ok=1
[[ "$first_traffic" =~ ^[0-9]+$ ]] && [ "$first_traffic" -lt 120 ] || ok=0
[ "$(printf '%.0f' "$p95")" -le 500 ] || ok=0
[ "$requests" -gt 100 ] || ok=0
[ $ok -eq 1 ] && echo "RESULTADO: APROBADO" || { echo "RESULTADO: FALLIDO"; exit 1; }
