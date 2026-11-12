#!/usr/bin/env bash
# Genera targets/*.json (file_sd de Prometheus) con las IPs privadas de .env. Ejecutar en el nodo de
# monitoreo después de editar .env; Prometheus detecta el cambio sin reiniciar.
set -euo pipefail
cd "$(dirname "$0")"
set -a; . ./.env; set +a
json() {  # json <puerto> <ip...>
  local port="$1"; shift
  printf '[{"targets":[%s]}]\n' "$(printf '"%s:'"$port"'",' "$@" | sed 's/,$//')"
}
read -r -a SERVICES <<< "${SERVICES_NODE_IPS:?Define SERVICES_NODE_IPS (IPs de los nodos de servicios separadas por espacios)}"
read -r -a ALL_NODES <<< "${ALL_NODE_IPS:?Define ALL_NODE_IPS (todas las VMs, para cAdvisor)}"
mkdir -p targets
json 8081 "${SERVICES[@]}" > targets/wellbeing.json
json 8082 "${SERVICES[@]}" > targets/marketplace.json
json 8083 "${SERVICES[@]}" > targets/realtime.json
json 8084 "${SERVICES[@]}" > targets/business-metrics.json
json 15692 "${DATA_NODE_IP:?}" > targets/rabbitmq.json
printf '[{"targets":["%s:9187","%s:9188"]}]\n' "$DATA_NODE_IP" "$DATA_NODE_IP" > targets/postgres.json
json 9121 "${DATA_NODE_IP}" > targets/redis.json
json 8089 "${ALL_NODES[@]}" > targets/cadvisor.json
echo "Objetivos generados en $(pwd)/targets"
