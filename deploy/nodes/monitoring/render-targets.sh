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
read -r -a ALL_NODES <<< "${ALL_NODE_IPS:?Define ALL_NODE_IPS (todas las VMs, para cAdvisor)}"
mkdir -p targets
# Cada microservicio tiene DOS VMs (principal y respaldo), con una réplica cada una en su puerto base.
replicas() {  # replicas <puerto> <ip...>
  local port="$1" list=""; shift
  for ip in "$@"; do list+="\"$ip:$port\","; done
  printf '[{"targets":[%s]}]\n' "${list%,}"
}
read -r -a W <<< "${WELLBEING_NODE_IPS:?}";   replicas 8081 "${W[@]}" > targets/wellbeing.json
read -r -a M <<< "${MARKETPLACE_NODE_IPS:?}"; replicas 8082 "${M[@]}" > targets/marketplace.json
read -r -a R <<< "${REALTIME_NODE_IPS:?}";    replicas 8083 "${R[@]}" > targets/realtime.json
json 15692 "${DATA_NODE_IP:?}" > targets/rabbitmq.json
printf '[{"targets":["%s:9187","%s:9188"]}]\n' "$DATA_NODE_IP" "$DATA_NODE_IP" > targets/postgres.json
json 9121 "${DATA_NODE_IP}" > targets/redis.json
json 8089 "${ALL_NODES[@]}" > targets/cadvisor.json
echo "Objetivos generados en $(pwd)/targets"
