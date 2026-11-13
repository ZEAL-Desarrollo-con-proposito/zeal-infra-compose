#!/bin/sh
# Réplica de PostgreSQL (streaming): si el volumen está vacío, clona el primario con pg_basebackup (-R deja la
# configuración de réplica) y arranca en modo standby; si ya tiene datos, solo arranca (sigue replicando, o,
# si se promovió con promote.sh, sigue como primario). Corre como usuario postgres.
set -eu
: "${PRIMARY_HOST:?}" "${PRIMARY_PORT:?}" "${REPL_USER:?}" "${REPL_PASSWORD:?}"
if [ ! -s "$PGDATA/PG_VERSION" ]; then
  echo "Volumen vacío: clonando el primario $PRIMARY_HOST:$PRIMARY_PORT"
  until pg_isready -q -h "$PRIMARY_HOST" -p "$PRIMARY_PORT"; do echo "esperando al primario…"; sleep 3; done
  PGPASSWORD="$REPL_PASSWORD" pg_basebackup -h "$PRIMARY_HOST" -p "$PRIMARY_PORT" -U "$REPL_USER" \
    -D "$PGDATA" -X stream -R -P
  chmod 700 "$PGDATA"
fi
exec docker-entrypoint.sh postgres -c wal_keep_size=1GB
