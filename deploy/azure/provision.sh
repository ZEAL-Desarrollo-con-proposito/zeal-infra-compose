#!/usr/bin/env bash
# R2-4 [COWORK] · Aprovisionamiento de la red y las VMs de ZEAL en Azure con Azure CLI.
# ⚠ ARCHIVO DE REFERENCIA: NO se ejecutó. Revisarlo en la sesión cowork, ajustar nombres/tamaños/región
# y correrlo con una cuenta autorizada. Crea recursos que cuestan dinero.
#
# Topología (docs/cowork/RUNBOOK_DESPLIEGUE_MULTINODO.md):
#   VNet 10.20.0.0/16 · subredes: edge 10.20.0.0/24, web 10.20.1.0/24, services 10.20.2.0/24
#   (UNA VM POR MICROSERVICIO: wellbeing .4, marketplace .5, realtime .6), data 10.20.3.0/24,
#   media 10.20.4.0/24, monitoring 10.20.5.0/24 — 8 VMs en total
#   IP pública SOLO en edge y media. Zona DNS privada zeal.internal enlazada a la VNet.
set -euo pipefail

RG="${RG:-rg-zeal-prod}"
LOCATION="${LOCATION:-eastus2}"
VNET=vnet-zeal
ADMIN_USER="${ADMIN_USER:-deploy}"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/zeal_deploy.pub}"
IMAGE="${IMAGE:-Ubuntu2404}"
OFFICE_CIDR="${OFFICE_CIDR:?Define OFFICE_CIDR (IP pública desde la que se administra, p. ej. 203.0.113.10/32)}"

az group create -n "$RG" -l "$LOCATION"
az network vnet create -g "$RG" -n "$VNET" --address-prefixes 10.20.0.0/16

declare -A SUBNETS=([edge]=10.20.0.0/24 [web]=10.20.1.0/24 [services]=10.20.2.0/24 [data]=10.20.3.0/24 [media]=10.20.4.0/24 [monitoring]=10.20.5.0/24)
for name in "${!SUBNETS[@]}"; do
  az network nsg create -g "$RG" -n "nsg-$name"
  az network vnet subnet create -g "$RG" --vnet-name "$VNET" -n "snet-$name" \
    --address-prefixes "${SUBNETS[$name]}" --network-security-group "nsg-$name"
done

rule() {  # rule <nsg> <prioridad> <nombre> <origen> <puertos> <protocolo>
  az network nsg rule create -g "$RG" --nsg-name "$1" --priority "$2" -n "$3" --direction Inbound --access Allow \
    --source-address-prefixes "$4" --destination-port-ranges $5 --protocol "$6"
}
# Borde: HTTP/HTTPS desde Internet; SSH solo desde la oficina (bastión del pipeline y del equipo).
rule nsg-edge 100 https Internet "80 443" Tcp
rule nsg-edge 110 https-udp Internet 443 Udp
rule nsg-edge 120 ssh "$OFFICE_CIDR" 22 Tcp
# Web: solo el borde.
rule nsg-web 100 from-edge 10.20.0.0/24 80 Tcp
# Borde: su NGINX también atiende en la IP privada al realtime-gateway (consulta a wellbeing balanceada).
rule nsg-edge 125 gateway-interno 10.20.2.0/24 8080 Tcp
# Microservicios (dos réplicas por VM: 808x y 809x): el borde (tráfico y SSH de despliegue) y monitoreo.
rule nsg-services 100 from-edge 10.20.0.0/24 "8081-8083 8091-8093 22" Tcp
rule nsg-services 110 from-monitoring 10.20.5.0/24 "8081-8083 8091-8093 8089" Tcp
# Datos: servicios (bases, Redis, RabbitMQ) y monitoreo (exportadores); SSH desde el borde.
rule nsg-data 100 from-services 10.20.2.0/24 "5432 5433 6379 61613" Tcp
rule nsg-data 110 from-monitoring 10.20.5.0/24 "15692 9187 9188 9121 8089 6379" Tcp   # 6379: métricas de negocio
rule nsg-data 120 ssh-from-edge 10.20.0.0/24 22 Tcp
# Medios: TURN y RTC desde Internet; señalización de LiveKit desde el borde.
rule nsg-media 100 turn-udp Internet "3478 49160-49200 50000-50100" Udp
rule nsg-media 110 turn-tcp Internet "443 3478 7881" Tcp
rule nsg-media 120 livekit-signal 10.20.0.0/24 "7880 22" Tcp
# Monitoreo: Grafana desde el borde; SSH desde el borde.
rule nsg-monitoring 100 from-edge 10.20.0.0/24 "3000 22" Tcp
rule nsg-monitoring 110 loki-from-vnet 10.20.0.0/16 3100 Tcp   # Alloy de cada nodo envía sus logs
for nsg in nsg-edge nsg-web nsg-media; do rule "$nsg" 130 cadvisor-from-monitoring 10.20.5.0/24 8089 Tcp; done

vm() {  # vm <nombre> <subred> <tamaño> <ip-privada> [public]
  local public_ip=(--public-ip-address "")
  [ "${5:-}" = public ] && public_ip=(--public-ip-address "pip-$1" --public-ip-sku Standard)
  az vm create -g "$RG" -n "vm-zeal-$1" --image "$IMAGE" --size "$3" --vnet-name "$VNET" --subnet "snet-$2" \
    --private-ip-address "$4" "${public_ip[@]}" --nsg "" --admin-username "$ADMIN_USER" --ssh-key-values "$SSH_KEY"
}
vm edge        edge       Standard_B2s  10.20.0.4 public
vm web         web        Standard_B1s  10.20.1.5
vm wellbeing   services   Standard_B2s  10.20.2.4
vm marketplace services   Standard_B2s  10.20.2.5
vm realtime    services   Standard_B2s  10.20.2.6
vm data        data       Standard_B2ms 10.20.3.4
vm media       media      Standard_B2s  10.20.4.4 public
vm monitoring  monitoring Standard_B2s  10.20.5.4

# DNS privado: cada microservicio apunta a su VM (NGINX lo resuelve con "resolve"; para escalar un
# microservicio a otra VM basta con agregar otro registro A bajo el mismo nombre).
az network private-dns zone create -g "$RG" -n zeal.internal
az network private-dns link vnet create -g "$RG" -z zeal.internal -n link-zeal -v "$VNET" -e false
az network private-dns record-set a add-record -g "$RG" -z zeal.internal -n wellbeing -a 10.20.2.4
az network private-dns record-set a add-record -g "$RG" -z zeal.internal -n marketplace -a 10.20.2.5
az network private-dns record-set a add-record -g "$RG" -z zeal.internal -n realtime -a 10.20.2.6
az network private-dns record-set a add-record -g "$RG" -z zeal.internal -n media -a 10.20.4.4
az network private-dns record-set a add-record -g "$RG" -z zeal.internal -n web -a 10.20.1.5
echo "Listo. Siguiente paso: docs/cowork/RUNBOOK_DESPLIEGUE_MULTINODO.md (instalar Docker y clonar repos en cada nodo)."
