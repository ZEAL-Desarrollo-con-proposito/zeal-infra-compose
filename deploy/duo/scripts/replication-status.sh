#!/usr/bin/env bash
# Estado de la replicación, para mirar antes de la prueba y después de un failover. Ejecutar en cualquier máquina.
set -euo pipefail
data="$(cd "$(dirname "$0")" && pwd)/../data"; cd "$data"; set -a; . ./.env; set +a
if [ "$COMPOSE_PROFILES" = primary ]; then
  for pair in "postgres-wellbeing:${WELLBEING_DB_OWNER_USER:-zeal_owner}:zeal_wellbeing_db" "postgres-marketplace:${MARKETPLACE_DB_OWNER_USER:-zeal_owner}:zeal_marketplace_db"; do
    IFS=: read -r svc user db <<< "$pair"
    echo "== $svc (primario): réplicas conectadas y retraso (bytes)"
    docker compose exec -T "$svc" psql -U "$user" -d "$db" -tAc \
      "SELECT coalesce(client_addr::text,'-') || ' ' || state || ' ' || (pg_current_wal_lsn() - replay_lsn) FROM pg_stat_replication" || true
  done
  echo "== redis (primario)"; docker compose exec -T redis redis-cli -a "$REDIS_PASSWORD" --no-auth-warning info replication | grep -E "role|connected_slaves|slave0"
else
  for pair in "postgres-wellbeing-replica:${WELLBEING_DB_OWNER_USER:-zeal_owner}:zeal_wellbeing_db" "postgres-marketplace-replica:${MARKETPLACE_DB_OWNER_USER:-zeal_owner}:zeal_marketplace_db"; do
    IFS=: read -r svc user db <<< "$pair"
    echo "== $svc: en recuperación (t = réplica, f = ya es primaria)"
    docker compose exec -T "$svc" psql -U "$user" -d "$db" -tAc "SELECT pg_is_in_recovery()"
  done
  echo "== redis-replica"; docker compose exec -T redis-replica redis-cli -a "$REDIS_PASSWORD" --no-auth-warning info replication | grep -E "role|master_link_status"
fi
