# shellcheck shell=bash
# Utilidades de las pruebas de disponibilidad (DISP-1/DISP-2). Requiere Docker y jq.
COMPOSE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
K6_IMAGE="grafana/k6:1.4.2"
OUT_DIR="$COMPOSE_DIR/tests/k6/out"
mkdir -p "$OUT_DIR"

compose() { docker compose --project-directory "$COMPOSE_DIR" "$@"; }
replica() { compose ps -q "$1" | sed -n "${2:-1}p"; }
now() { date +%s; }

# Simula la caída real de una réplica: el proceso muere solo (como un crash de la JVM). Se mata desde
# el espacio de PIDs del host porque `docker kill`/`docker stop` cuentan como parada manual y Docker
# NO aplica la política de reinicio en ese caso.
crash() { docker run --rm --pid=host alpine:3.20 kill -9 "$(docker inspect -f '{{.State.Pid}}' "$1")"; }

# Segundos hasta que el contenedor vuelve a estar "healthy" (máximo $2 s).
wait_healthy() {
  local container="$1" limit="${2:-120}" start; start=$(now)
  sleep 2
  while [ $(( $(now) - start )) -lt "$limit" ]; do
    if [ "$(docker inspect -f '{{.State.Status}}/{{if .State.Health}}{{.State.Health.Status}}{{end}}' "$container")" = "running/healthy" ]; then
      echo $(( $(now) - start )); return 0
    fi
    sleep 1
  done
  echo "timeout"; return 1
}

run_k6() {  # run_k6 <script> <summary-file> [VAR=valor...]
  local script="$1" summary="$2"; shift 2
  local envs=(); for kv in "$@"; do envs+=(-e "$kv"); done
  docker run --rm --network host -u "$(id -u)" -v "$COMPOSE_DIR/tests/k6:/scripts" \
    -e SUMMARY_FILE="/scripts/out/$summary" "${envs[@]}" "$K6_IMAGE" run --quiet "/scripts/$script"
}

metric() { jq -r "$2" "$OUT_DIR/$1"; }
