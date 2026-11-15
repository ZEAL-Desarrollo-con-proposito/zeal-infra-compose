#!/usr/bin/env bash
# DISP-1 sobre el despliegue REAL en Azure (dos máquinas, deploy/duo): con carga constante desde ESTE equipo
# (otra máquina distinta a las del despliegue) se APAGA la máquina A con `az vm deallocate` y se mide:
# errores visibles, postulaciones confirmadas vs guardadas, y a quién atendió cada tramo. Al final se
# ENCIENDE A y se mide cuánto tarda en volver a atender tráfico.
#
#   SITE=zeal-xxxxxx.trafficmanager.net JWT_SECRET=... ./tests/disp/azure-disp1.sh
#   Opcionales: RG (rg-zeal), VM_A (vm-zeal-a), VM_B (vm-zeal-b), A_PUB, RATE (30), DURATION (150), OFF_AT (30)
# Requiere: az (sesión iniciada), docker, jq. JWT_SECRET es el del despliegue (las pruebas firman tokens con él).
#
# Para apagar B (la primaria de los datos) NO sirve este script: ahí hay que ejecutar promote.sh en A; ver
# docs/cowork/RUNBOOK_DESPLIEGUE_DUO.md sección 9.2.
set -euo pipefail
# shellcheck source=lib.sh source-path=SCRIPTDIR
source "$(dirname "$0")/lib.sh"
: "${SITE:?Define SITE (nombre de Traffic Manager)}" "${JWT_SECRET:?Define JWT_SECRET del despliegue}"
RG="${RG:-rg-zeal}"; VM_A="${VM_A:-vm-zeal-a}"; VM_B="${VM_B:-vm-zeal-b}"
RATE="${RATE:-30}"; DURATION="${DURATION:-150}"; OFF_AT="${OFF_AT:-30}"
A_PUB="${A_PUB:-$(az network public-ip show -g "$RG" -n pip-zeal-a --query ipAddress -o tsv)}"
S=azure-disp1-summary.json

echo "== DISP-1 en Azure · $RATE req/s por https://$SITE durante ${DURATION}s; a los ${OFF_AT}s se apaga $VM_A"
t_start="$(date -u +%FT%TZ)"
run_k6 disp-load.js "$S" ZEAL_API="https://$SITE" JWT_SECRET="$JWT_SECRET" RATE="$RATE" DURATION="${DURATION}s" \
  > "$OUT_DIR/azure-disp1-k6.log" 2>&1 &
k6_pid=$!
sleep "$OFF_AT"
t_off="$(date -u +%FT%TZ)"; echo "   $(date +%T) APAGANDO $VM_A (az vm deallocate)"
az vm deallocate -g "$RG" -n "$VM_A" --no-wait
wait "$k6_pid" || true
t_end="$(date -u +%FT%TZ)"

errors="$(metric $S '.metrics.visible_errors.values.count // 0')"; failed="$(metric $S '.metrics.http_req_failed.values.rate')"
requests="$(metric $S '.metrics.http_reqs.values.count')"; p95="$(metric $S '.metrics.http_req_duration.values["p(95)"]')"
max="$(metric $S '.metrics.http_req_duration.values.max')"
project="$(metric $S '.setup_data.projectId')"; confirmed="$(metric $S '.metrics.confirmed_writes.values.count // 0')"
stored="$(az vm run-command invoke -g "$RG" -n "$VM_B" --command-id RunShellScript -o json --scripts \
  "docker exec zeal-data-postgres-marketplace-1 psql -U zeal_owner -d zeal_marketplace_db -tAc \"select count(*) from marketplace.applications where project_id = '$project'\"" \
  | jq -r '.value[0].message' | grep -E '^[0-9]+$' | head -1)"

printf '\n| Medida | Resultado | Objetivo |\n|---|---|---|\n'
printf '| Peticiones | %s | — |\n| Errores visibles | %s (%.3f %%) | 0 |\n' "$requests" "$errors" "$(echo "$failed * 100" | bc -l)"
printf '| p95 / máximo | %.0f ms / %.0f ms | — |\n' "$p95" "$max"
printf '| Postulaciones confirmadas / guardadas | %s / %s | iguales (0 perdidas) |\n' "$confirmed" "$stored"
printf '| Ventana | %s → %s (A apagada a las %s) | — |\n' "$t_start" "$t_end" "$t_off"

echo; echo "== Se enciende $VM_A de nuevo y se mide cuánto tarda en atender tráfico"
t0=$(date +%s); az vm start -g "$RG" -n "$VM_A" --no-wait
t_vm=""; t_web=""
while [ $(( $(date +%s) - t0 )) -lt 600 ]; do
  if curl -fsS --max-time 4 --resolve "$SITE:443:$A_PUB" "https://$SITE/gateway/health" > /dev/null 2>&1; then
    t_web=$(( $(date +%s) - t0 )); break
  fi
  sleep 3
done
echo "   $VM_A atiende HTTPS ${t_web:-(no en 10 min)} s después de encenderla"
ok=1
[ "$errors" -eq 0 ] || ok=0
[ "$confirmed" = "$stored" ] || ok=0
[ "$requests" -gt 100 ] || ok=0
[ "$ok" -eq 1 ] && echo "RESULTADO DISP-1: APROBADO" || { echo "RESULTADO DISP-1: FALLIDO"; exit 1; }
