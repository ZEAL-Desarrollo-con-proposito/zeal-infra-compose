#!/usr/bin/env bash
# R2-5 · Prueba de restauración SIN tocar la base real: levanta un PostgreSQL desechable, restaura el
# respaldo y compara el número de filas de cada tabla con la base de origen.
#   pg-restore-test.sh wellbeing /var/backups/zeal/wellbeing_20261111T031500Z.dump
set -euo pipefail

name="${1:?Uso: pg-restore-test.sh <wellbeing|marketplace> <archivo.dump>}"
file="${2:?Falta el archivo .dump}"
case "$name" in
  wellbeing)   source_container="${WELLBEING_CONTAINER:-zeal-data-postgres-wellbeing-1}";     db=zeal_wellbeing_db;   user="${WELLBEING_DB_USER:-zeal_owner}"; schema=wellbeing ;;
  marketplace) source_container="${MARKETPLACE_CONTAINER:-zeal-data-postgres-marketplace-1}"; db=zeal_marketplace_db; user="${MARKETPLACE_DB_USER:-zeal_owner}"; schema=marketplace ;;
  *) echo "Base desconocida: $name" >&2; exit 1 ;;
esac

scratch="zeal-restore-test-$$"
trap 'docker rm -f "$scratch" > /dev/null 2>&1 || true' EXIT
docker run -d --name "$scratch" -e POSTGRES_DB="$db" -e POSTGRES_USER="$user" -e POSTGRES_PASSWORD=restore-test \
  postgres:15-alpine > /dev/null
until docker exec "$scratch" pg_isready -U "$user" -d "$db" > /dev/null 2>&1; do sleep 1; done
sleep 2

started=$(date +%s)
# Los roles no viajan en el respaldo: se omiten dueños y permisos en la copia de prueba.
docker exec -i "$scratch" pg_restore -U "$user" -d "$db" --no-owner --no-privileges --exit-on-error < "$file"
echo "Restaurado en $(( $(date +%s) - started )) s"

count_rows() {  # count_rows <contenedor>  → "tabla filas" por línea
  docker exec "$1" psql -U "$user" -d "$db" -tAF' ' -c \
    "select table_name, (xpath('/row/c/text()', query_to_xml(format('select count(*) as c from %I.%I', table_schema, table_name), false, true, '')))[1]::text
     from information_schema.tables where table_schema = '$schema' and table_type = 'BASE TABLE' order by 1"
}
diff <(count_rows "$source_container") <(count_rows "$scratch") > /dev/null \
  && { echo "OK: todas las tablas de $schema tienen las mismas filas que el origen"; count_rows "$scratch" | sed 's/^/   /'; } \
  || { echo "DIFERENCIAS (puede ser normal si hubo escrituras después del respaldo):"; diff <(count_rows "$source_container") <(count_rows "$scratch") || true; exit 1; }
