#!/usr/bin/env bash
# Variante con VARIAS CUENTAS de Azure (una por integrante): cada cuenta crea SOLO sus VMs, en su propia
# red, y las VMs se hablan por IP PÚBLICA estática con reglas de firewall (NSG) que solo admiten las IP de
# las otras VMs. (Con una sola cuenta usar provision.sh, que usa una red privada compartida.)
# ⚠ ARCHIVO DE REFERENCIA: revisar antes de ejecutar. Crea recursos que cuestan dinero.
#
# Dos fases, porque las IP públicas solo se conocen después de crear las VMs:
#   1) ./provision-account.sh crear  <vm> [<vm>...]    # crea la VM con IP pública estática y solo SSH
#   2) (todos se pasan sus IP) → completar peers.env
#   3) ./provision-account.sh reglas <vm> [<vm>...]    # abre los puertos de cada VM solo a quien corresponde
#
# VMs válidas (12): edge web-1 web-2 wellbeing-1 wellbeing-2 marketplace-1 marketplace-2 realtime-1 realtime-2
#                   data media monitoring    (cada microservicio y el front tienen una VM principal y otra de respaldo)
# Variables: RG (grupo de recursos), LOCATION, SSH_KEY (llave pública), OFFICE_CIDR (IP desde donde se
# administra); SSH_FROM=Internet solo en las VMs de servicios, para que GitHub Actions despliegue por SSH
# (la VM solo acepta llave, nunca contraseña);
# administra), PEERS_FILE (peers.env con las IP públicas de las 8 VMs; ver peers.env.example).
set -euo pipefail

fase="${1:?Uso: provision-account.sh <crear|reglas> <vm>...}"; shift
RG="${RG:-rg-zeal}"
LOCATION="${LOCATION:-eastus2}"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/zeal_admin.pub}"
OFFICE_CIDR="${OFFICE_CIDR:?Define OFFICE_CIDR (IP pública desde la que administras, p. ej. 203.0.113.10/32)}"
PEERS_FILE="${PEERS_FILE:-$(dirname "$0")/peers.env}"

# Tamaños pensados para 4 vCPU por cuenta (cuota gratuita típica) y 16 vCPU en total entre las 4 cuentas:
# VMs de servicios 1 vCPU / 2 GB (una réplica de 1 GB de memoria cada una); edge, datos, medios y monitoreo 2 vCPU.
# Si su cuota permite más, SERVICE_SIZE=Standard_B2s da más holgura a las VMs de servicios.
SERVICE_SIZE="${SERVICE_SIZE:-Standard_B1ms}"
declare -A SIZE=([edge]=Standard_B2s [web-1]=Standard_B1s [web-2]=Standard_B1s
                 [wellbeing-1]=$SERVICE_SIZE [wellbeing-2]=$SERVICE_SIZE [marketplace-1]=$SERVICE_SIZE
                 [marketplace-2]=$SERVICE_SIZE [realtime-1]=$SERVICE_SIZE [realtime-2]=$SERVICE_SIZE
                 [data]=Standard_B2ms [media]=Standard_B2s [monitoring]=Standard_B2s)

rule() {  # rule <nsg> <prioridad> <nombre> <origen(es)> <puertos> <protocolo>
  # shellcheck disable=SC2086
  az network nsg rule create -g "$RG" --nsg-name "$1" --priority "$2" -n "$3" --direction Inbound --access Allow \
    --source-address-prefixes $4 --destination-port-ranges $5 --protocol "$6" > /dev/null
}

crear() {
  local vm="$1"
  az group create -n "$RG" -l "$LOCATION" > /dev/null
  az network vnet create -g "$RG" -n vnet-zeal --address-prefixes 10.20.0.0/16 \
    --subnet-name snet-zeal --subnet-prefixes 10.20.0.0/24 > /dev/null 2>&1 || true
  az network nsg create -g "$RG" -n "nsg-$vm" > /dev/null
  rule "nsg-$vm" 100 ssh "${SSH_FROM:-$OFFICE_CIDR}" 22 Tcp   # SSH_FROM=Internet en las VMs de servicios: el pipeline entra por llave
  az network public-ip create -g "$RG" -n "pip-$vm" --sku Standard --allocation-method Static > /dev/null
  az vm create -g "$RG" -n "vm-zeal-$vm" --image Ubuntu2404 --size "${SIZE[$vm]}" --vnet-name vnet-zeal \
    --subnet snet-zeal --public-ip-address "pip-$vm" --nsg "nsg-$vm" --admin-username deploy \
    --ssh-key-values "$SSH_KEY" > /dev/null
  echo "$vm: IP pública $(az network public-ip show -g "$RG" -n "pip-$vm" --query ipAddress -o tsv)" \
       "· IP privada $(az vm show -d -g "$RG" -n "vm-zeal-$vm" --query privateIps -o tsv)"
}

reglas() {
  [ -s "$PEERS_FILE" ] || { echo "Falta $PEERS_FILE (copiar peers.env.example y completar)" >&2; exit 1; }
  # shellcheck disable=SC1090
  . "$PEERS_FILE"
  local vm="$1" n="nsg-$1"
  local web="$WEB_1_IP $WEB_2_IP" wb="$WELLBEING_1_IP $WELLBEING_2_IP" mp="$MARKETPLACE_1_IP $MARKETPLACE_2_IP"
  local rt="$REALTIME_1_IP $REALTIME_2_IP"
  local all="$EDGE_IP $web $wb $mp $rt $DATA_IP $MEDIA_IP $MONITORING_IP"
  case "$vm" in
    edge)       rule "$n" 110 http "Internet" "80 443" Tcp
                rule "$n" 111 http3 "Internet" 443 Udp
                rule "$n" 120 gateway-interno "$rt" 8080 Tcp ;;                  # realtime → wellbeing balanceado
    web-*)      rule "$n" 110 from-edge "$EDGE_IP" 80 Tcp ;;
    wellbeing-*) rule "$n" 110 from-edge-mon "$EDGE_IP $MONITORING_IP" 8081 Tcp ;;
    marketplace-*) rule "$n" 110 from-edge-mon "$EDGE_IP $MONITORING_IP" 8082 Tcp ;;
    realtime-*) rule "$n" 110 from-edge-mon "$EDGE_IP $MONITORING_IP" 8083 Tcp ;;
    data)       rule "$n" 110 bases "$wb $mp $MONITORING_IP" "5432 5433" Tcp
                rule "$n" 111 redis "$wb $mp $rt $MONITORING_IP" 6379 Tcp
                rule "$n" 112 stomp "$rt" 61613 Tcp
                rule "$n" 113 metricas "$MONITORING_IP" "15692 9187 9188 9121" Tcp ;;
    media)      rule "$n" 110 turn-udp "Internet" "3478 49160-49200 50000-50100" Udp
                rule "$n" 111 turn-tcp "Internet" "443 3478 7881" Tcp
                rule "$n" 112 livekit-senal "$EDGE_IP" 7880 Tcp ;;
    monitoring) rule "$n" 110 grafana "$EDGE_IP" 3000 Tcp
                rule "$n" 111 loki "$all" 3100 Tcp ;;
    *) echo "VM desconocida: $vm" >&2; exit 1 ;;
  esac
  # cAdvisor (métricas de contenedores) de cada VM, solo para el monitoreo
  [ "$vm" = monitoring ] || rule "$n" 130 cadvisor "$MONITORING_IP" 8089 Tcp
  echo "$vm: reglas aplicadas"
}

for vm in "$@"; do
  [[ -v SIZE[$vm] ]] || { echo "VM desconocida: $vm" >&2; exit 1; }
  case "$fase" in
    crear) crear "$vm" ;;
    reglas) reglas "$vm" ;;
    *) echo "Fase desconocida: $fase (crear|reglas)" >&2; exit 1 ;;
  esac
done
