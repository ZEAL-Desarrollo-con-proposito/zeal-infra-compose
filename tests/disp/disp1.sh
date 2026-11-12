#!/usr/bin/env bash
# DISP-1 · Falla de una instancia (HU-BE-19). Con carga constante a través de NGINX se "cae" una
# réplica de cada servicio (crash del proceso) y se mide: errores visibles, tiempo hasta que la réplica
# vuelve sola y operaciones confirmadas perdidas (postulaciones 201 que no están en la base).
#   RATE=40 DURATION=120s CRASH_AFTER=30 ./tests/disp/disp1.sh
set -euo pipefail
# shellcheck source=lib.sh source-path=SCRIPTDIR
source "$(dirname "$0")/lib.sh"
RATE="${RATE:-40}"; DURATION="${DURATION:-120s}"; CRASH_AFTER="${CRASH_AFTER:-30}"

echo "== DISP-1 · $RATE req/s durante $DURATION; caída de una réplica de cada servicio a los ${CRASH_AFTER}s"
run_k6 disp-load.js disp1-summary.json RATE="$RATE" DURATION="$DURATION" > "$OUT_DIR/disp1-k6.log" 2>&1 &
k6_pid=$!
sleep "$CRASH_AFTER"

declare -A recovery
for service in wellbeing marketplace realtime; do
  container="$(replica "$service" 1)"
  echo "   $(date +%T) cae $(docker inspect -f '{{.Name}}' "$container" | tr -d /)"
  crash "$container"
  ( wait_healthy "$container" 120 > "$OUT_DIR/disp1-recovery-$service" ) &
done
for job in $(jobs -p); do [ "$job" = "$k6_pid" ] || wait "$job" || true; done
for service in wellbeing marketplace realtime; do recovery[$service]="$(cat "$OUT_DIR/disp1-recovery-$service")"; done
wait "$k6_pid" || true   # k6 sale con código ≠ 0 si un umbral falla; el veredicto se calcula abajo

S=disp1-summary.json
project="$(metric $S '.setup_data.projectId')"
confirmed="$(metric $S '.metrics.confirmed_writes.values.count // 0')"
stored="$(docker exec zeal-postgres-marketplace psql -U zeal_user -d zeal_marketplace_db -tAc \
  "select count(*) from marketplace.applications where project_id = '$project'")"
requests="$(metric $S '.metrics.http_reqs.values.count')"
failed_rate="$(metric $S '.metrics.http_req_failed.values.rate')"
errors="$(metric $S '.metrics.visible_errors.values.count // 0')"
p95="$(metric $S '.metrics.http_req_duration.values["p(95)"]')"
lost=$(( confirmed - stored ))

printf '\n| Medida | Resultado | Objetivo |\n|---|---|---|\n'
printf '| Peticiones | %s | — |\n' "$requests"
printf '| Errores visibles | %s (%.3f %%) | 0 |\n' "$errors" "$(echo "$failed_rate * 100" | bc -l)"
for service in wellbeing marketplace realtime; do printf '| Réplica de %s de vuelta (healthy) | %s s | < 60 s |\n' "$service" "${recovery[$service]}"; done
printf '| Postulaciones confirmadas (201) | %s | — |\n| Postulaciones en la base | %s | = confirmadas |\n' "$confirmed" "$stored"
printf '| Operaciones confirmadas perdidas | %s | 0 |\n| p95 | %.0f ms | — |\n' "$lost" "$p95"
grep -h "visible_errors" "$OUT_DIR/disp1-k6.log" | head -3 || true

ok=1
[ "${requests:-0}" -gt 100 ] || { echo "k6 no generó carga: revisa tests/k6/out/disp1-k6.log"; ok=0; }
[ "$lost" -eq 0 ] || ok=0
for service in wellbeing marketplace realtime; do [[ "${recovery[$service]}" =~ ^[0-9]+$ ]] && [ "${recovery[$service]}" -lt 60 ] || ok=0; done
[ "$errors" -eq 0 ] || ok=0
[ $ok -eq 1 ] && echo "RESULTADO: APROBADO" || { echo "RESULTADO: FALLIDO"; exit 1; }
