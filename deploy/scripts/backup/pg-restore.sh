#!/usr/bin/env bash
# R2-5 · Restaura un respaldo de pg-backup.sh sobre la base REAL (reemplaza su contenido).
#   pg-restore.sh wellbeing /var/backups/zeal/wellbeing_20261111T031500Z.dump --yes
# Antes de restaurar en producción: detener los servicios que usan esa base (runbook, plan de reversión)
# y probar el archivo con pg-restore-test.sh.
set -euo pipefail

name="${1:?Uso: pg-restore.sh <wellbeing|marketplace> <archivo.dump> --yes}"
file="${2:?Falta el archivo .dump}"
[ "${3:-}" = "--yes" ] || { echo "Esto reemplaza la base $name. Repite con --yes para confirmar." >&2; exit 1; }
[ -s "$file" ] || { echo "No existe $file" >&2; exit 1; }
if [ -f "$file.sha256" ]; then (cd "$(dirname "$file")" && sha256sum -c "$(basename "$file").sha256"); fi

case "$name" in
  wellbeing)   container="${WELLBEING_CONTAINER:-zeal-data-postgres-wellbeing-1}";     db=zeal_wellbeing_db;   user="${WELLBEING_DB_USER:-zeal_owner}" ;;
  marketplace) container="${MARKETPLACE_CONTAINER:-zeal-data-postgres-marketplace-1}"; db=zeal_marketplace_db; user="${MARKETPLACE_DB_USER:-zeal_owner}" ;;
  *) echo "Base desconocida: $name" >&2; exit 1 ;;
esac

docker exec -i "$container" pg_restore -U "$user" -d "$db" --clean --if-exists --single-transaction --exit-on-error < "$file"
echo "Restaurada $name desde $(basename "$file")"
