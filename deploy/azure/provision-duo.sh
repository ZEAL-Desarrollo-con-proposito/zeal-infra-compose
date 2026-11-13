#!/usr/bin/env bash
# Despliegue en DOS MÁQUINAS (deploy/duo): crea la VM A o la B con IP pública estática y abre sus puertos SOLO a
# quien corresponde. Pueden estar en la misma cuenta de Azure o en cuentas distintas (se hablan por IP pública).
# ⚠ ARCHIVO DE REFERENCIA: revisar antes de ejecutar. Crea recursos que cuestan dinero.
#
#   1) ./provision-duo.sh crear a          # (en la cuenta de A)   imprime la IP pública
#      ./provision-duo.sh crear b          # (en la cuenta de B)
#   2) completar peers-duo.env con A_IP y B_IP
#   3) ./provision-duo.sh reglas a  y  ./provision-duo.sh reglas b
#
# Variables: RG, LOCATION, SSH_KEY (llave pública), OFFICE_CIDR (IP desde la que administras),
#            SIZE (por defecto Standard_D4s_v5: 4 vCPU / 16 GB; ver el runbook para el dimensionamiento),
#            SSH_FROM=Internet para que GitHub Actions despliegue por SSH (solo llave, nunca contraseña),
#            PEERS_FILE (por defecto peers-duo.env).
set -euo pipefail
fase="${1:?Uso: provision-duo.sh <crear|reglas> <a|b>}"; vm="${2:?Falta la máquina (a|b)}"
[[ "$vm" =~ ^[ab]$ ]] || { echo "La máquina debe ser a o b" >&2; exit 1; }
RG="${RG:-rg-zeal}"; LOCATION="${LOCATION:-eastus2}"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/zeal_admin.pub}"
OFFICE_CIDR="${OFFICE_CIDR:?Define OFFICE_CIDR (p. ej. 203.0.113.10/32)}"
PEERS_FILE="${PEERS_FILE:-$(dirname "$0")/peers-duo.env}"
SIZE="${SIZE:-Standard_D4s_v5}"
n="nsg-zeal-$vm"

rule() {  # rule <prioridad> <nombre> <origen(es)> <puertos> <protocolo>
  # shellcheck disable=SC2086
  az network nsg rule create -g "$RG" --nsg-name "$n" --priority "$1" -n "$2" --direction Inbound --access Allow \
    --source-address-prefixes $3 --destination-port-ranges $4 --protocol "$5" > /dev/null
}

crear() {
  az group create -n "$RG" -l "$LOCATION" > /dev/null
  az network vnet create -g "$RG" -n vnet-zeal --address-prefixes 10.20.0.0/16 \
    --subnet-name snet-zeal --subnet-prefixes 10.20.0.0/24 > /dev/null 2>&1 || true
  az network nsg create -g "$RG" -n "$n" > /dev/null
  rule 100 ssh "${SSH_FROM:-$OFFICE_CIDR}" 22 Tcp
  az network public-ip create -g "$RG" -n "pip-zeal-$vm" --sku Standard --allocation-method Static > /dev/null
  az vm create -g "$RG" -n "vm-zeal-$vm" --image Ubuntu2404 --size "$SIZE" --vnet-name vnet-zeal \
    --subnet snet-zeal --public-ip-address "pip-zeal-$vm" --nsg "$n" --admin-username deploy \
    --ssh-key-values "$SSH_KEY" --os-disk-size-gb 64 > /dev/null
  echo "$vm: IP pública $(az network public-ip show -g "$RG" -n "pip-zeal-$vm" --query ipAddress -o tsv)" \
       "· IP privada $(az vm show -d -g "$RG" -n "vm-zeal-$vm" --query privateIps -o tsv)"
}

reglas() {
  [ -s "$PEERS_FILE" ] || { echo "Falta $PEERS_FILE (copiar peers-duo.env.example y completar)" >&2; exit 1; }
  # shellcheck disable=SC1090
  . "$PEERS_FILE"
  local peer; [ "$vm" = a ] && peer="$B_IP" || peer="$A_IP"
  rule 110 web "Internet" "80 443" Tcp
  rule 111 http3 "Internet" 443 Udp
  # La otra máquina: balanceo (servicios, front y NGINX) y bases de datos / réplica
  rule 120 servicios-par "$peer" "8080 8081 8082 8083 3080" Tcp
  rule 121 datos-par "$peer" "5432 5433 6379 61613" Tcp
  # Medios (LiveKit + coturn) y monitoreo viven en la máquina B
  if [ "$vm" = b ]; then
    rule 130 turn-udp "Internet" "3478 49160-49200 50000-50100" Udp
    rule 131 turn-tcp "Internet" "3478 5349 7881" Tcp
    rule 132 livekit-par "$A_IP" 7880 Tcp
    rule 133 monitoreo-par "$A_IP" "3000 3100" Tcp
  fi
  # cAdvisor (métricas de contenedores) para el monitoreo (en B)
  [ "$vm" = b ] || rule 140 cadvisor "$B_IP" 8089 Tcp
  echo "$vm: reglas aplicadas"
}

case "$fase" in crear) crear ;; reglas) reglas ;; *) echo "Fase desconocida (crear|reglas)" >&2; exit 1 ;; esac
