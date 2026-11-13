#!/usr/bin/env bash
# Reincorpora una máquina que estuvo caída como RÉPLICA del nuevo primario (la que ejecutó promote.sh).
# BORRA los datos locales de PostgreSQL y Redis de esta máquina (están desfasados) y los vuelve a copiar.
#   deploy/duo/scripts/rejoin-as-replica.sh <IP-del-nuevo-primario>
# Para volver a dejar los roles originales, repite el proceso al revés (promote.sh + rejoin) en una ventana de mantenimiento.
set -euo pipefail
new_primary="${1:?Uso: rejoin-as-replica.sh <IP del nuevo primario>}"
here="$(cd "$(dirname "$0")" && pwd)"; data="$here/../data"; app="$here/../app"
if [ "${YES:-0}" != 1 ]; then
  read -r -p "Se BORRAN los datos de PostgreSQL/Redis de ESTA máquina y se copian de $new_primary. [escribe BORRAR] " ok
  [ "$ok" = BORRAR ] || { echo "Cancelado."; exit 1; }
fi
cd "$data"
docker compose --profile primary --profile replica down -v
sed -i "s/^COMPOSE_PROFILES=.*/COMPOSE_PROFILES=replica/;s/^PRIMARY_HOST=.*/PRIMARY_HOST=${new_primary}/" .env
docker compose up -d
cd "$app"
sed -i "s/^DATA_HOST=.*/DATA_HOST=${new_primary}/" .env
docker compose up -d wellbeing marketplace realtime
echo "Esta máquina replica ahora de $new_primary (la copia inicial tarda según el tamaño de las bases)."
