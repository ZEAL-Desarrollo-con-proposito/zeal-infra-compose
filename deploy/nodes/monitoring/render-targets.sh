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
# Cada microservicio tiene su VM con dos réplicas (puertos 808x y 809x). Si un microservicio tiene más
# de una VM, poner sus IPs separadas por espacios en *_NODE_IPS.
replicas() {  # replicas <puerto> <ip...>
  local port="$1" list=""; shift
  for ip in "$@"; do list+="\"$ip:$port\",\"$ip:$((port + 10))\","; done
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
