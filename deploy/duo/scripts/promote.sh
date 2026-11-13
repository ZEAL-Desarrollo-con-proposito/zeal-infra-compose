#!/usr/bin/env bash
# FAILOVER de datos: se ejecuta en la máquina que quedó viva y tiene las RÉPLICAS (rol replica). Convierte sus
# réplicas de PostgreSQL y Redis en primarias y reapunta los servicios de esta máquina a sus bases locales.
#   deploy/duo/scripts/promote.sh            # pide confirmación y se niega si el primario aún responde
#   FORCE=1 deploy/duo/scripts/promote.sh    # promueve aunque el primario responda (solo si SABES que está caído)
# Riesgo (split-brain): si el primario sigue vivo y se promueve la réplica, habría dos bases que aceptan
# escrituras. Por eso se comprueba primero y, tras promover, la máquina vieja NO debe volver a conectarse
# a los servicios: se reincorpora con rejoin-as-replica.sh (borra sus datos y copia los de ésta).
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"; data="$here/../data"; app="$here/../app"
set -a; . "$data/.env"; set +a
[ "${COMPOSE_PROFILES:-}" = replica ] || { echo "Esta máquina no tiene el rol replica (COMPOSE_PROFILES=${COMPOSE_PROFILES:-})." >&2; exit 1; }
: "${PRIMARY_HOST:?}"

if [ "${FORCE:-0}" != 1 ] && pg_isready -q -h "$PRIMARY_HOST" -p "${PRIMARY_PG_WELLBEING_PORT:-5432}" -t 5 2>/dev/null; then
  echo "El primario ($PRIMARY_HOST) RESPONDE. No se promueve: habría dos primarios. Si sabes que está caído, FORCE=1." >&2
  exit 1
fi
if [ "${YES:-0}" != 1 ]; then
  read -r -p "Promover esta máquina a primaria de los datos (el primario $PRIMARY_HOST se considera caído)? [escribe PROMOVER] " ok
  [ "$ok" = PROMOVER ] || { echo "Cancelado."; exit 1; }
fi

cd "$data"
for pair in "postgres-wellbeing-replica:${WELLBEING_DB_OWNER_USER:-zeal_owner}:zeal_wellbeing_db" \
            "postgres-marketplace-replica:${MARKETPLACE_DB_OWNER_USER:-zeal_owner}:zeal_marketplace_db"; do
  IFS=: read -r svc user db <<< "$pair"
  echo "→ Promoviendo $svc"
  docker compose exec -T "$svc" psql -U "$user" -d "$db" -tAc "SELECT pg_promote(wait => true, wait_seconds => 60)" | grep -q t
  docker compose exec -T "$svc" psql -U "$user" -d "$db" -tAc "SELECT pg_is_in_recovery()" | grep -q f
done
echo "→ Promoviendo redis-replica"
docker compose exec -T redis-replica redis-cli -a "$REDIS_PASSWORD" --no-auth-warning replicaof no one
# Que un reinicio no la vuelva réplica del primario caído: sin PRIMARY_HOST arranca como primaria.
sed -i "s/^PRIMARY_HOST=.*/PRIMARY_HOST=/" .env
PRIMARY_HOST="" docker compose up -d redis-replica   # (la variable ya exportada pisaría a la del .env)

echo "→ Reapuntando los servicios de esta máquina a sus bases locales"
if [ -f "$app/.env" ]; then
  cd "$app"
  sed -i "s/^DATA_HOST=.*/DATA_HOST=${PRIVATE_IP}/" .env
  docker compose up -d wellbeing marketplace realtime
else
  echo "(aviso: no hay $app/.env; no se reapuntaron servicios)"
fi
echo "Listo. Esta máquina es ahora la PRIMARIA de los datos. Pendiente (a mano):"
echo "  · En el monitoreo, DATA_NODE_IP=${PRIVATE_IP} y ejecutar render-targets.sh."
echo "  · Cuando la otra máquina vuelva: rejoin-as-replica.sh en ELLA (no la conectes antes)."
