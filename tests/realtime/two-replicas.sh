#!/usr/bin/env bash
# DT-4: ejecuta two-replicas.mjs contra las dos réplicas del gateway de docker-compose.yml.
# Linux: las IPs de los contenedores son alcanzables desde el host. En Docker Desktop (macOS/Windows)
# ejecútalo dentro de la red: docker run --rm --network zeal-infra-compose_default -v "$PWD/..":/t -w /t/realtime node:20 ./two-replicas.sh
set -euo pipefail
cd "$(dirname "$0")"
COMPOSE_DIR="$(cd ../.. && pwd)"
mapfile -t ids < <(docker compose --project-directory "$COMPOSE_DIR" ps -q realtime)
if [ "${#ids[@]}" -lt 2 ]; then
  echo "Se necesitan al menos 2 réplicas de realtime (hay ${#ids[@]})." >&2
  exit 1
fi
ip() { docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$1"; }
[ -d node_modules ] || npm install --silent
REPLICA_A_URL="http://$(ip "${ids[0]}"):8083" REPLICA_B_URL="http://$(ip "${ids[1]}"):8083" node two-replicas.mjs
