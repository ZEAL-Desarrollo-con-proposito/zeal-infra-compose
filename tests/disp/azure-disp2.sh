#!/usr/bin/env bash
# DISP-2 sobre el despliegue REAL en Azure: "se agrega una instancia del servicio más exigido (marketplace) SIN
# cambiar código ni reiniciar las demás" y se mide cuánto tarda en recibir tráfico (meta < 2 min, p95 ≤ 500 ms).
# Con carga constante desde ESTE equipo, la VM B ejecuta (todo medido dentro de la VM, con su reloj):
#   1. docker compose --profile extra up -d marketplace-extra      (nueva instancia en el puerto 8092)
#   2. espera su readiness
#   3. escribe nginx/conf.d/extra/marketplace-extra.conf y recarga NGINX (nginx -s reload: sin cortar conexiones)
#   4. espera la primera petición atendida por la instancia nueva (campo "upstream" del log de NGINX)
# Al final la quita (archivo + reload + stop). Las demás instancias no se reinician en ningún momento.
#
#   SITE=zeal-xxxxxx.trafficmanager.net JWT_SECRET=... ./tests/disp/azure-disp2.sh
set -euo pipefail
# shellcheck source=lib.sh source-path=SCRIPTDIR
source "$(dirname "$0")/lib.sh"
: "${SITE:?Define SITE}" "${JWT_SECRET:?Define JWT_SECRET del despliegue}"
RG="${RG:-rg-zeal}"; VM_B="${VM_B:-vm-zeal-b}"; RATE="${RATE:-40}"; DURATION="${DURATION:-210}"; ADD_AT="${ADD_AT:-40}"
S=azure-disp2-summary.json
vm() { az vm run-command invoke -g "$RG" -n "$VM_B" --command-id RunShellScript -o json --scripts "$1" \
  | jq -r '.value[0].message' | awk '/^\[stdout\]/{f=1; next} /^\[stderr\]/{f=0} f'; }

echo "== DISP-2 en Azure · $RATE req/s por https://$SITE · a los ~${ADD_AT}s se agrega marketplace-extra en $VM_B"
run_k6 disp-load.js "$S" ZEAL_API="https://$SITE" JWT_SECRET="$JWT_SECRET" RATE="$RATE" DURATION="${DURATION}s" \
  > "$OUT_DIR/azure-disp2-k6.log" 2>&1 &
k6_pid=$!
sleep "$ADD_AT"

result="$(vm '  # NOSONAR S5332: el bloque es un script remoto con tráfico interno (red privada de Azure)
set -u
SCHEME=http
cd /opt/zeal/zeal-infra-compose/deploy/duo/app
IP=$(grep ^PRIVATE_IP= .env | cut -d= -f2)
now() { date +%s.%N; }
t0=$(now)
sudo -u deploy -H docker compose --profile extra up -d marketplace-extra > /dev/null 2>&1
until curl -fsS --max-time 3 "$SCHEME://$IP:8092/actuator/health/readiness" 2>/dev/null | grep -q "\"UP\""; do sleep 1; [ $(echo "$(now) - $t0 > 150" | bc) = 1 ] && { echo "ERROR readiness"; exit 1; }; done
t_ready=$(now)
printf "server %s:8092 max_fails=3 fail_timeout=10s;\n" "$IP" > ../../../nginx/conf.d/extra/marketplace-extra.conf
docker exec zeal-app-api-gateway-1 nginx -s reload > /dev/null 2>&1
t_conf=$(now)
t_first=""
until [ -n "$t_first" ]; do
  if docker logs --since "$(date -u -d @${t0%.*} +%FT%TZ)" zeal-app-api-gateway-1 2>&1 | grep -q "\"upstream\":\"$IP:8092\""; then t_first=$(now); fi
  sleep 0.5; [ $(echo "$(now) - $t0 > 170" | bc) = 1 ] && break
done
echo "listo=$(echo "$t_ready - $t0" | bc) reload=$(echo "$t_conf - $t0" | bc) trafico=$( [ -n "$t_first" ] && echo "$t_first - $t0" | bc || echo NA)"
sleep 20
echo "peticiones_a_8092=$(docker logs --since "$(date -u -d @${t0%.*} +%FT%TZ)" zeal-app-api-gateway-1 2>&1 | grep -c "\"upstream\":\"$IP:8092\"")"
echo "reinicios_otras_instancias=$(docker inspect -f "{{.RestartCount}} {{.State.StartedAt}}" zeal-app-marketplace-1 zeal-app-wellbeing-1 zeal-app-realtime-1 | tr "\n" ";")"
')"
echo "$result"  # NOSONAR S5332: valores de una prueba interna, sin protocolo en claro hacia Internet
wait "$k6_pid" || true

echo "== Se quita la instancia extra"
vm 'cd /opt/zeal/zeal-infra-compose/deploy/duo/app; rm -f ../../../nginx/conf.d/extra/marketplace-extra.conf; docker exec zeal-app-api-gateway-1 nginx -s reload >/dev/null 2>&1; sudo -u deploy -H docker compose --profile extra stop marketplace-extra >/dev/null 2>&1; echo quitada' | tail -1

errors="$(metric $S '.metrics.visible_errors.values.count // 0')"; requests="$(metric $S '.metrics.http_reqs.values.count')"
p95m="$(metric $S '.metrics.latency_marketplace.values["p(95)"]')"; p95="$(metric $S '.metrics.http_req_duration.values["p(95)"]')"
traffic="$(echo "$result" | sed -n 's/.*trafico=\([0-9.NA]*\).*/\1/p')"  # NOSONAR S5332: valores de una prueba interna, sin protocolo en claro hacia Internet
printf '\n| Medida | Resultado | Objetivo |\n|---|---|---|\n'
printf '| Tiempo hasta que la instancia nueva recibe tráfico | %s s | < 120 s |\n' "${traffic:-?}"  # NOSONAR S5332: valores de una prueba interna, sin protocolo en claro hacia Internet
printf '| p95 de marketplace durante toda la prueba | %.0f ms | ≤ 500 ms |\n' "$p95m"
printf '| p95 global / errores visibles / peticiones | %.0f ms / %s / %s | 0 errores |\n' "$p95" "$errors" "$requests"
ok=1
[[ "$errors" -eq 0 ]] || ok=0
[[ "$traffic" =~ ^[0-9.]+$ ]] && [[ "$(echo "$traffic < 120" | bc)" = 1 ]] || ok=0  # NOSONAR S5332: valores de una prueba interna, sin protocolo en claro hacia Internet
[[ "$(echo "$p95m <= 500" | bc)" = 1 ]] || ok=0
[[ "$ok" -eq 1 ]] && echo "RESULTADO DISP-2: APROBADO" || { echo "RESULTADO DISP-2: FALLIDO"; exit 1; }
