# Runbook · Despliegue de ZEAL en Azure — una máquina virtual por microservicio

**Tareas:** R2-4, R2-5, R2-6, DT-5, R2-17, R2-18/R2-20, R2-33 · **Decisiones:** ADR-12, ADR-13
Todo lo de este documento está preparado y validado en local (sintaxis de Compose, NGINX, scripts y un
ensayo real del despliegue por réplicas con reversión). **Nada se ejecutó contra Azure.**

## Topología: 8 máquinas virtuales

Cada microservicio tiene **su propia VM** y en ella corren **dos réplicas** (puertos `808x` y `809x`).
El NGINX del borde reparte entre las dos réplicas y saca de rotación la que falle.

| VM | IP privada | Qué corre | IP pública | Carpeta |
|---|---|---|---|---|
| `vm-zeal-edge` | 10.20.0.4 | Caddy (HTTPS) + NGINX (balanceador) | **Sí** | `deploy/nodes/edge` |
| `vm-zeal-web` | 10.20.1.5 | SPA (frontend) | No | `deploy/nodes/web` |
| `vm-zeal-wellbeing` | 10.20.2.4 | wellbeing ×2 (8081, 8091) | No | `deploy/nodes/wellbeing` |
| `vm-zeal-marketplace` | 10.20.2.5 | marketplace ×2 (8082, 8092) | No | `deploy/nodes/marketplace` |
| `vm-zeal-realtime` | 10.20.2.6 | realtime-gateway ×2 (8083, 8093) | No | `deploy/nodes/realtime` |
| `vm-zeal-data` | 10.20.3.4 | PostgreSQL ×2, Redis, RabbitMQ, respaldos | No | `deploy/nodes/data` |
| `vm-zeal-media` | 10.20.4.4 | LiveKit + coturn | **Sí** | `deploy/nodes/media` |
| `vm-zeal-monitoring` | 10.20.5.4 | Prometheus, Loki, Grafana, Alertmanager, métricas de negocio | No | `deploy/nodes/monitoring` |

> **Límite que deben conocer:** con una sola VM por microservicio, si se cae **una réplica** la otra sigue
> atendiendo (DISP-1), pero si se cae **la VM completa** ese microservicio queda sin servicio hasta que
> Azure la reinicie. El documento de arquitectura pide réplicas "repartidas en dos máquinas": para
> cumplirlo al pie de la letra se crea una segunda VM del microservicio (paso 12, 10 minutos) — todo está
> preparado para eso sin cambiar código ni reiniciar nada.

Comunicación entre VMs (lo abre el NSG del script): borde → microservicios (808x/809x), borde → web (80),
borde → medios (7880), borde → monitoreo (3000), microservicios → datos (5432, 5433, 6379, 61613),
realtime → borde (8080, para consultar a wellbeing balanceado), monitoreo → todos (métricas),
todos → monitoreo (3100, logs).

## 0. Antes de empezar

| Rol | Responsable | VM |
|---|---|---|
| Red (VNet, NSG, DNS) y coordinación | _____________ | — |
| Borde | _____________ | `vm-zeal-edge` |
| Web (SPA) | _____________ | `vm-zeal-web` |
| wellbeing | _____________ | `vm-zeal-wellbeing` |
| marketplace | _____________ | `vm-zeal-marketplace` |
| realtime-gateway | _____________ | `vm-zeal-realtime` |
| Datos y respaldos | _____________ | `vm-zeal-data` |
| Medios (LiveKit, coturn) | _____________ | `vm-zeal-media` |
| Monitoreo | _____________ | `vm-zeal-monitoring` |
| GitHub (secretos, SonarCloud, protección de main) | _____________ | — |
| Microsoft Entra ID | _____________ | — |

**Prerrequisitos**

- [ ] **El frontend debe tener fusionado el login con Microsoft.** El `main` actual del SPA todavía llama a
      `POST /api/auth/login` con contraseña, que este backend ya no tiene: con ese frontend nadie puede
      iniciar sesión. Contrato: `docs/contratos/auth-microsoft.md`.
- [ ] Suscripción de Azure con cuota para 8 VMs (≈ 16 vCPU en la región) y Azure CLI con sesión (`az login`).
- [ ] Dominio con acceso al DNS: `zeal.<dominio>` (borde) y `turn.<dominio>` (medios).
- [ ] Llave SSH del equipo (`~/.ssh/zeal_admin`) y otra solo para el pipeline (`zeal_deploy`):
      `ssh-keygen -t ed25519 -f ~/.ssh/zeal_admin` y `ssh-keygen -t ed25519 -N "" -f ~/.ssh/zeal_deploy`.
- [ ] Los repos del backend con el Sprint 2 en `main` (los workflows publican las imágenes desde `main`).
- [ ] Secretos generados **una sola vez** y guardados en el gestor de contraseñas del equipo:
  ```bash
  for s in JWT_SECRET REDIS_PASSWORD RABBITMQ_PASSWORD TURN_SECRET LIVEKIT_API_SECRET \
           WELLBEING_DB_OWNER_PASSWORD WELLBEING_DB_APP_PASSWORD MARKETPLACE_DB_OWNER_PASSWORD \
           MARKETPLACE_DB_APP_PASSWORD GRAFANA_ADMIN_PASSWORD; do echo "$s=$(openssl rand -hex 32)"; done
  ```

## 1. Red y máquinas (≈ 30 min)

```bash
cd zeal-infra-compose/deploy/azure
less provision.sh                                    # revisar región, tamaños y nombres
OFFICE_CIDR=<IP pública desde donde administran>/32 SSH_KEY=~/.ssh/zeal_admin.pub ./provision.sh
az vm list-ip-addresses -g rg-zeal-prod -o table     # anotar las IP públicas de edge y media
```

DNS público: `A zeal.<dominio> → IP de edge` y `A turn.<dominio> → IP de media`.
**Verificar:** `az network private-dns record-set a list -g rg-zeal-prod -z zeal.internal -o table`
muestra `wellbeing → 10.20.2.4`, `marketplace → 10.20.2.5`, `realtime → 10.20.2.6`, `media`, `web`.

¿Prefieren el portal? Lo mismo a mano: grupo de recursos → red virtual con las 6 subredes → un NSG por
subred con las reglas de `provision.sh` → 8 VMs Ubuntu 24.04 con IP privada fija (solo edge y media con
IP pública) → zona DNS privada `zeal.internal` enlazada a la red.

## 2. Preparar cada VM (cada responsable en la suya)

Se entra por el borde, que hace de bastión: `ssh -i ~/.ssh/zeal_admin -J deploy@<IP edge> deploy@10.20.x.y`.

```bash
sudo apt-get update && sudo apt-get install -y docker.io docker-compose-v2 git jq curl
sudo usermod -aG docker deploy && newgrp docker
sudo mkdir -p /opt/zeal && sudo chown deploy: /opt/zeal && cd /opt/zeal
git clone https://github.com/<organizacion>/zeal-infra-compose.git
# Solo en las VMs que bajan imágenes privadas (wellbeing, marketplace, realtime, web):
echo "<token de GitHub con read:packages>" | docker login ghcr.io -u <usuario> --password-stdin
```

## 3. VM de datos — primero, todo depende de ella

```bash
cd /opt/zeal/zeal-infra-compose/deploy/nodes/data
cp .env.example .env && nano .env        # PRIVATE_IP=10.20.3.4 y los secretos de bases, Redis y RabbitMQ
docker compose up -d && docker compose ps    # todo "healthy"
```
**Verificar:**
```bash
docker compose exec postgres-wellbeing psql -U zeal_owner -d zeal_wellbeing_db -c '\du'   # zeal_owner y zeal_app
docker compose exec redis sh -c 'redis-cli -a "$REDIS_PASSWORD" --no-auth-warning ping'      # PONG
docker compose exec rabbitmq rabbitmq-diagnostics -q check_port_listener 61613
```
**Respaldo diario (R2-5):**
```bash
sudo mkdir -p /var/backups/zeal && sudo crontab -e      # agregar la línea:
15 3 * * * cd /opt/zeal/zeal-infra-compose && BACKUP_DIR=/var/backups/zeal deploy/scripts/backup/pg-backup.sh >> /var/log/zeal-backup.log 2>&1
sudo deploy/scripts/backup/pg-backup.sh                                                   # primera corrida
sudo deploy/scripts/backup/pg-restore-test.sh wellbeing   /var/backups/zeal/wellbeing_<fecha>.dump
sudo deploy/scripts/backup/pg-restore-test.sh marketplace /var/backups/zeal/marketplace_<fecha>.dump
```

## 4. VM de medios (LiveKit + coturn)

```bash
sudo apt-get install -y certbot
# Abrir temporalmente 80/tcp en nsg-media y pedir el certificado de turn.<dominio>:
sudo certbot certonly --standalone -d turn.<dominio> --agree-tos -m <correo-del-equipo>
sudo mkdir -p /etc/zeal/turn-certs
sudo cp /etc/letsencrypt/live/turn.<dominio>/fullchain.pem /etc/zeal/turn-certs/turn.crt
sudo cp /etc/letsencrypt/live/turn.<dominio>/privkey.pem  /etc/zeal/turn-certs/turn.key
sudo chmod 644 /etc/zeal/turn-certs/*          # coturn corre sin privilegios; cerrar 80/tcp al terminar
cd /opt/zeal/zeal-infra-compose/deploy/nodes/media
cp .env.example .env && nano .env              # PRIVATE_IP, PUBLIC_IP, TURN_DOMAIN, TURN_SECRET, LIVEKIT_*
docker compose up -d && docker compose ps
```
**Verificar (DT-6)** desde un portátil, idealmente en una red que bloquee UDP:
`TURN_HOST=turn.<dominio> TURN_TLS_PORT=443 TURN_SECRET=<secreto> ./tools/turn-check/turn-check.sh`

## 5. Publicar las imágenes de los microservicios (GitHub)

En cada repo de servicio (wellbeing, marketplace, realtime-gateway): **Actions → Deploy → Run workflow**.
El job `publish` sube la imagen a `ghcr.io/<organizacion>/zeal-<servicio>:<sha>` y `:latest`. El job
`deploy` fallará hasta completar el paso 9 (aún no tiene secretos): es lo esperado en este punto.

## 6. Las tres VMs de microservicios

Mismo procedimiento en cada una, cambiando el nombre. **wellbeing primero** (realtime depende de él).

```bash
SERVICIO=wellbeing            # o marketplace, o realtime
cd /opt/zeal
cp zeal-infra-compose/deploy/nodes/$SERVICIO/docker-compose.yml docker-compose.yml
cp zeal-infra-compose/deploy/nodes/$SERVICIO/.env.example .env && nano .env
docker compose pull && docker compose up -d
docker compose ps                 # las dos réplicas "healthy" (≈ 1 min; la primera corre las migraciones)
```

| VM | Qué completar en `.env` |
|---|---|
| wellbeing | `GHCR_OWNER`, `PUBLIC_URL`, `JWT_SECRET`, `REDIS_PASSWORD`, `DB_OWNER_PASSWORD`/`DB_APP_PASSWORD` (los de **wellbeing**), `TURN_URLS`, `TURN_SECRET`, `LIVEKIT_*`, `OIDC_*` (paso 8) |
| marketplace | `GHCR_OWNER`, `PUBLIC_URL`, `JWT_SECRET` (el mismo), `REDIS_PASSWORD`, `DB_OWNER_PASSWORD`/`DB_APP_PASSWORD` (los de **marketplace**), `LIVEKIT_*` |
| realtime | `GHCR_OWNER`, `PUBLIC_URL`, `JWT_SECRET` (el mismo), `REDIS_PASSWORD`, `RABBITMQ_PASSWORD`, `EDGE_NODE_IP=10.20.0.4` |

**Verificar en cada VM** (puerto base 8081 / 8082 / 8083 y su réplica en +10):
```bash
curl -s 10.20.2.4:8081/actuator/health/readiness; curl -s 10.20.2.4:8091/actuator/health/readiness   # {"status":"UP"}
```
El realtime-gateway necesita el borde arriba (paso 7) para autorizar chats y salas; arranca igual sin él.

## 7. VM web y VM de borde

```bash
# web — si el repo del frontend publica su imagen en GHCR:
cd /opt/zeal/zeal-infra-compose/deploy/nodes/web && cp .env.example .env && nano .env && docker compose up -d
# (alternativa sin registro: git clone del frontend en la VM, `docker build -t ghcr.io/<org>/zeal-frontend-client:latest .`)

# borde
cd /opt/zeal/zeal-infra-compose/deploy/nodes/edge && cp .env.example .env && nano .env && docker compose up -d
docker compose logs caddy | grep -i certificate          # certificado de zeal.<dominio> obtenido
```
**Verificar:**
```bash
curl -s https://zeal.<dominio>/gateway/health                                           # {"status":"UP"}
curl -s -o /dev/null -w '%{http_code}\n' https://zeal.<dominio>/actuator/prometheus    # 404: no se expone
for i in $(seq 1 10); do curl -s -o /dev/null https://zeal.<dominio>/api/talleres; done
docker compose logs api-gateway | grep '^{' | jq -r .upstream | sort | uniq -c           # 10.20.2.5:8082 y :8092
```

## 8. Microsoft Entra ID (login)

1. *App registrations → New registration*: "ZEAL", cuentas de este directorio.
2. *Redirect URI (Web)*: `https://zeal.<dominio>/api/auth/microsoft/callback`.
3. *Certificates & secrets*: nuevo secreto de cliente → `OIDC_CLIENT_SECRET`.
4. *Token configuration*: agregar el claim opcional `email` al ID token.
5. En el `.env` de la VM de wellbeing: `OIDC_ISSUER_URI=https://login.microsoftonline.com/<tenant-id>/v2.0`,
   `OIDC_CLIENT_ID`, `OIDC_CLIENT_SECRET` → `docker compose up -d wellbeing-a`, esperar *healthy*, luego `wellbeing-b`.
6. Los correos de `user_accounts` deben coincidir con los de Entra ID. Con `DEMO_DATA_ENABLED=false` solo
   existen las cuentas de las migraciones: cargar las reales antes de la demostración.

## 9. Pipeline de despliegue (GitHub)

En **cada** repo de servicio: *Settings → Environments → production* con estos secretos:

| Secreto | Valor |
|---|---|
| `DEPLOY_SSH_KEY` | contenido de `~/.ssh/zeal_deploy` (privada) |
| `DEPLOY_KNOWN_HOSTS` | salida de `ssh-keyscan <IP pública edge>` + la clave de host de la VM del servicio (`ssh-keyscan 10.20.2.x` ejecutado desde el borde) |
| `BASTION_HOST` | IP pública del borde |
| `SERVICE_HOST` | IP privada de la VM de **ese** microservicio (10.20.2.4 / .5 / .6) |

`zeal_deploy.pub` va en `~deploy/.ssh/authorized_keys` del borde y de las tres VMs de microservicios.
**Probar:** *Actions → Deploy → Run workflow*. Debe actualizar la réplica `a`, esperar su readiness y
luego la `b`. Desde entonces cada push a `main` que pase el CI se despliega solo.

SonarCloud y protección de `main`: `CHECKLIST_COWORK.md` (R2-18, R2-20).

## 10. VM de monitoreo

```bash
cd /opt/zeal/zeal-infra-compose/deploy/nodes/monitoring
cp .env.example .env && nano .env           # IPs, PUBLIC_URL, GRAFANA_ADMIN_PASSWORD, REDIS_PASSWORD
nano alertmanager.yml                       # webhook real del equipo (Teams/Discord/Slack) o correo
./render-targets.sh && docker compose up -d --build
```
Agente (cAdvisor + envío de logs) en **cada una de las 8 VMs**:
```bash
cd /opt/zeal/zeal-infra-compose/deploy/nodes/monitoring
printf 'PRIVATE_IP=%s\nLOKI_URL=http://10.20.5.4:3100/loki/api/v1/push\n' <IP privada de esta VM> > agent.env
docker compose -f monitoring-agent.yml --env-file agent.env up -d
```
**Verificar:** `https://zeal.<dominio>/grafana` pide login y el tablero "ZEAL · Estado de la plataforma"
muestra 2 réplicas arriba por servicio.

## 11. Verificación final

| Prueba | Cómo | Evidencia |
|---|---|---|
| Login real (SEG-2) | SPA con una cuenta precargada, una no registrada y cancelando en Microsoft | `SEG.md` |
| Caída de réplica (DISP-1) | carga con `tests/k6/disp-load.js` desde otra máquina; en la VM del servicio matar el proceso de una réplica (`sudo kill -9 $(docker inspect -f '{{.State.Pid}}' <contenedor>)`) | `DISP.md` |
| Escalado (DISP-2) | paso 12 con carga duplicada | `DISP.md` |
| Robo de sesión (SEG-4) | reutilizar un refresh token y consultar las 6 réplicas | `SEG.md` |
| REND-1 / REND-2 / estrés | `tests/k6/rend*.js` con `ZEAL_API=https://zeal.<dominio>` (requiere el `JWT_SECRET` de un entorno de pruebas, no el de producción) | `REND.md` |
| Alertas (OBS-1, SEG-4) | detener PostgreSQL de marketplace 3 min con carga; reutilizar un refresh token | `OBS.md` |
| Relé TURN (DT-6) | `tools/turn-check/` desde una red sin UDP | `HU-DT-02.md` |

## 12. Agregar una segunda VM a un microservicio (escalar o tolerar la caída de una VM)

```bash
# 1. Crear la VM (ejemplo: segunda de marketplace) en la subred de servicios
az vm create -g rg-zeal-prod -n vm-zeal-marketplace-2 --image Ubuntu2404 --size Standard_B2s \
  --vnet-name vnet-zeal --subnet snet-services --private-ip-address 10.20.2.15 --public-ip-address "" \
  --nsg "" --admin-username deploy --ssh-key-values ~/.ssh/zeal_admin.pub
# 2. Pasos 2 y 6 en la VM nueva (mismo .env, con PRIVATE_IP=10.20.2.15)
# 3. Anunciarla: NGINX la descubre solo en ~10 s, sin reiniciar nada
az network private-dns record-set a add-record -g rg-zeal-prod -z zeal.internal -n marketplace -a 10.20.2.15
# 4. Monitoreo: MARKETPLACE_NODE_IPS="10.20.2.5 10.20.2.15" en su .env y ./render-targets.sh
```
El pipeline despliega en `SERVICE_HOST`; para la segunda VM, repetir el job con su IP (o ejecutar
`deploy-service.sh marketplace <sha>` en ella).

## 13. Plan de reversión

| Situación | Acción |
|---|---|
| Una versión nueva no queda lista | `deploy-service.sh` ya vuelve a la versión anterior y el job falla. A mano: `IMAGE_TAG=<sha anterior>` en `/opt/zeal/.env` y `docker compose up -d` |
| Migración de base con problemas | Detener las dos réplicas del servicio, `pg-restore.sh <base> <archivo> --yes` en la VM de datos, volver al SHA anterior |
| Login con Microsoft falla | Revisar `security_audit` (columna `detail`) y `OIDC_*`. No hay vuelta a contraseñas |
| Se cae la VM de un microservicio | Azure la reinicia y Docker levanta las réplicas (`restart: unless-stopped`); si no vuelve, paso 12 |
| Volver al despliegue de un solo servidor | La VM de la demo con `docker-compose.prod.yml` sigue siendo válida: apuntar el DNS a ella |

Al terminar: marcar `CHECKLIST_COWORK.md`, guardar resultados en `docs/evidencias/` y **apagar las VMs
que no se usen** (cuestan aunque estén ociosas): `az vm deallocate -g rg-zeal-prod --ids $(az vm list -g rg-zeal-prod --query "[].id" -o tsv)`.
