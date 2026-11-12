#!/usr/bin/env bash
# R2-16 · Ejecuta seg4-session-theft.mjs contra las réplicas de docker-compose.yml y verifica la auditoría.
set -euo pipefail
cd "$(dirname "$0")"
COMPOSE_DIR="$(cd ../.. && pwd)"
ips() { docker compose --project-directory "$COMPOSE_DIR" ps -q "$1" | xargs -r docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' | jq -R . | jq -sc .; }
REPLICAS="{\"wellbeing\":$(ips wellbeing),\"marketplace\":$(ips marketplace),\"realtime\":$(ips realtime)}"
[ -d ../realtime/node_modules ] || (cd ../realtime && npm install --silent)
[ -e node_modules ] || ln -s ../realtime/node_modules node_modules   # mismas dependencias (stompjs, sockjs)
set +e
out="$(REPLICAS="$REPLICAS" node seg4-session-theft.mjs 2>&1)"
code=$?
set -e
echo "$out" | grep -v '^AUDIT_SINCE='
since="$(grep '^AUDIT_SINCE=' <<<"$out" | cut -d= -f2)"
rows="$(docker exec zeal-postgres-wellbeing psql -U "${POSTGRES_USER:-zeal_user}" -d zeal_wellbeing_db -tAc \
  "select count(*) from wellbeing.security_audit where event_type = 'REFRESH_REUTILIZADO' and user_id = 'usr-empleado-001' and occurred_at >= '$since'")"
if [ "${rows:-0}" -ge 1 ]; then echo "OK   auditoría: REFRESH_REUTILIZADO registrado ($rows)"; else echo "FAIL auditoría sin REFRESH_REUTILIZADO"; code=1; fi
exit $code
