#!/usr/bin/env bash
# R2-5 · Respaldo diario de las dos bases de ZEAL con pg_dump (formato custom, comprimido) y rotación.
#
# Nodo de datos (cowork), en el crontab de root:
#   15 3 * * * /opt/zeal/zeal-infra-compose/deploy/scripts/backup/pg-backup.sh >> /var/log/zeal-backup.log 2>&1
#
# Variables (con valores por defecto para el nodo de datos; en local ver docs/evidencias/DISP.md):
#   BACKUP_DIR=/var/backups/zeal  BACKUP_RETENTION_DAYS=14
#   WELLBEING_CONTAINER / MARKETPLACE_CONTAINER   contenedores de PostgreSQL
#   WELLBEING_DB_USER / MARKETPLACE_DB_USER       usuario propietario (el de las migraciones)
set -euo pipefail

BACKUP_DIR="${BACKUP_DIR:-/var/backups/zeal}"
RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-14}"
WELLBEING_CONTAINER="${WELLBEING_CONTAINER:-zeal-data-postgres-wellbeing-1}"
MARKETPLACE_CONTAINER="${MARKETPLACE_CONTAINER:-zeal-data-postgres-marketplace-1}"
WELLBEING_DB_USER="${WELLBEING_DB_USER:-zeal_owner}"
MARKETPLACE_DB_USER="${MARKETPLACE_DB_USER:-zeal_owner}"

[ -n "$BACKUP_DIR" ] && [ "$BACKUP_DIR" != "/" ] || { echo "BACKUP_DIR inválido" >&2; exit 1; }
mkdir -p "$BACKUP_DIR"
chmod 700 "$BACKUP_DIR"   # Los respaldos contienen datos personales y clínicos.
stamp="$(date -u +%Y%m%dT%H%M%SZ)"

backup() {  # backup <nombre> <contenedor> <base> <usuario>
  local name="$1" container="$2" db="$3" user="$4"
  local file="$BACKUP_DIR/${name}_${stamp}.dump"
  docker exec "$container" pg_dump -U "$user" -d "$db" -Fc -Z 6 > "$file.partial"
  # Un respaldo que pg_restore no puede leer no es un respaldo.
  docker exec -i "$container" pg_restore --list > /dev/null < "$file.partial"
  mv "$file.partial" "$file"
  sha256sum "$file" | sed "s#$BACKUP_DIR/##" > "$file.sha256"
  echo "$(date -u +%FT%TZ) OK $name → $(basename "$file") ($(du -h "$file" | cut -f1))"
}

backup wellbeing   "$WELLBEING_CONTAINER"   zeal_wellbeing_db   "$WELLBEING_DB_USER"
backup marketplace "$MARKETPLACE_CONTAINER" zeal_marketplace_db "$MARKETPLACE_DB_USER"

# Rotación: solo archivos de respaldo de ZEAL dentro de BACKUP_DIR, más viejos que la retención.
find "$BACKUP_DIR" -maxdepth 1 -type f \( -name 'wellbeing_*.dump*' -o -name 'marketplace_*.dump*' \) \
  -mtime +"$RETENTION_DAYS" -print -delete | sed 's/^/rotado: /'
