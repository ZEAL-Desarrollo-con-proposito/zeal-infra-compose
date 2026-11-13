#!/bin/sh
# Primario: crea el rol de replicación y admite sus conexiones (se ejecuta solo al crear el volumen,
# después de 01-app-role.sh).
set -eu
: "${REPL_USER:?}" "${REPL_PASSWORD:?}"
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" -v u="$REPL_USER" -v p="$REPL_PASSWORD" <<'SQL'
SELECT format('CREATE ROLE %I WITH REPLICATION LOGIN PASSWORD %L', :'u', :'p')
WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = :'u') \gexec
SQL
echo "host replication $REPL_USER 0.0.0.0/0 scram-sha-256" >> "$PGDATA/pg_hba.conf"
echo "Rol de replicación $REPL_USER listo"
