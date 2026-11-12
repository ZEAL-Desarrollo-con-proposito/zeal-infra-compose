# Runbook · Despliegue multinodo de ZEAL en Azure (sesión cowork)

**Tareas:** R2-4, R2-5, R2-6, DT-5, R2-17, R2-18/R2-20, R2-33 · **Decisiones:** ADR-12, ADR-13
**Objetivo de la sesión:** que el despliegue sea mecánico: seguir este documento de arriba abajo.
Todo lo de esta carpeta está preparado y probado en local; **nada se ejecutó contra Azure**.

## 0. Antes de empezar

| Rol | Responsable | Nodo(s) |
|---|---|---|
| Coordinación y red (VNet, NSG, DNS) | _____________ | — |
| Borde (Caddy + NGINX) | _____________ | `vm-zeal-edge` |
| Web (SPA) | _____________ | `vm-zeal-web` |
| Servicios (wellbeing, marketplace, realtime, business-metrics) | _____________ | `vm-zeal-services-1`, `vm-zeal-services-2` |
| Datos (PostgreSQL ×2, Redis, RabbitMQ, respaldos) | _____________ | `vm-zeal-data` |
| Medios (LiveKit, coturn) | _____________ | `vm-zeal-media` |
| Monitoreo (Prometheus, Loki, Grafana, Alertmanager) | _____________ | `vm-zeal-monitoring` |
| GitHub (secretos, entornos, protección de main, SonarCloud) | _____________ | — |
| Microsoft Entra ID (registro de la app) | _____________ | — |

**Prerrequisitos**

- [ ] Suscripción de Azure con permiso para crear red y VMs; Azure CLI con sesión (`az login`).
- [ ] Dominio público con acceso al DNS: `zeal.<dominio>` (borde) y `turn.<dominio>` (medios).
- [ ] Llave SSH del equipo para administrar (`~/.ssh/zeal_admin`) y otra **solo para el pipeline** (`zeal_deploy`).
- [ ] Organización de GitHub con los 5 repos y permiso de administración.
- [ ] Tenant de Microsoft Entra ID donde registrar la app.
- [ ] Este repo en `main` con los commits del Sprint 2 (backend y FE).
- [ ] Generar los secretos **una sola vez** y guardarlos en el gestor de contraseñas del equipo:
  ```bash
  for s in JWT_SECRET REDIS_PASSWORD RABBITMQ_PASSWORD TURN_SECRET LIVEKIT_API_SECRET \
           WELLBEING_DB_OWNER_PASSWORD WELLBEING_DB_APP_PASSWORD MARKETPLACE_DB_OWNER_PASSWORD \
           MARKETPLACE_DB_APP_PASSWORD GRAFANA_ADMIN_PASSWORD; do echo "$s=$(openssl rand -hex 32)"; done
  ```
  Sin comillas simples en las contraseñas de base de datos (las usa una migración).

**Topología** (VNet `10.20.0.0/16`; solo borde y medios tienen IP pública)

| Nodo | Subred | IP privada | Expone |
|---|---|---|---|
| edge | 10.20.0.0/24 | 10.20.0.4 | 80/443 a Internet |
| web | 10.20.1.0/24 | 10.20.1.5 | 80 al borde |
| services-1 / services-2 | 10.20.2.0/24 | 10.20.2.4 / .5 | 8081-8084 al borde y monitoreo |
| data | 10.20.3.0/24 | 10.20.3.4 | 5432, 5433, 6379, 61613 a servicios; exportadores a monitoreo |
| media | 10.20.4.0/24 | 10.20.4.4 | 443/tcp, 3478, 7881, 49160-49200/udp, 50000-50100/udp a Internet; 7880 al borde |
| monitoring | 10.20.5.0/24 | 10.20.5.4 | 3000 al borde; 3100 a la VNet |

## 1. Red y máquinas (≈ 30 min) — responsable de red

```bash
cd zeal-infra-compose/deploy/azure
less provision.sh                                   # revisar nombres, región, tamaños
OFFICE_CIDR=<IP pública de la sala>/32 SSH_KEY=~/.ssh/zeal_admin.pub ./provision.sh
az vm list-ip-addresses -g rg-zeal-prod -o table    # anotar IP pública de edge y media
```

DNS público: `A zeal.<dominio> → IP de edge`, `A turn.<dominio> → IP de media`.
**Verificar:** `az network private-dns record-set a list -g rg-zeal-prod -z zeal.internal -o table`
muestra `wellbeing`, `marketplace`, `realtime` con las dos IPs de servicios, `media` y `web`.

## 2. Preparación común de cada VM (en paralelo, cada responsable en su nodo)

El borde es el bastión: `ssh -J deploy@<IP edge> deploy@10.20.x.y`.

```bash
sudo apt-get update && sudo apt-get install -y docker.io docker-compose-v2 git jq
sudo usermod -aG docker deploy && newgrp docker
sudo mkdir -p /opt/zeal && sudo chown deploy: /opt/zeal && cd /opt/zeal
git clone https://github.com/<organizacion>/zeal-infra-compose.git
echo "<token de GitHub con read:packages>" | docker login ghcr.io -u <usuario> --password-stdin
```

## 3. Nodo de datos — primero (los demás dependen de él)

```bash
cd /opt/zeal/zeal-infra-compose/deploy/nodes/data
cp .env.example .env && nano .env                   # PRIVATE_IP=10.20.3.4 y los secretos
docker compose up -d && docker compose ps           # todo "healthy"
```

**Verificar:**
```bash
docker compose exec postgres-wellbeing psql -U zeal_owner -d zeal_wellbeing_db -c '\du'   # zeal_owner y zeal_app (sin superusuario)
docker compose exec redis sh -c 'redis-cli -a "$REDIS_PASSWORD" --no-auth-warning ping'      # PONG
docker compose exec rabbitmq rabbitmq-diagnostics -q check_port_listener 61613               # sin error
```

**Respaldo diario (R2-5):**
```bash
sudo mkdir -p /var/backups/zeal
sudo crontab -e   # agregar:
15 3 * * * cd /opt/zeal/zeal-infra-compose && BACKUP_DIR=/var/backups/zeal BACKUP_RETENTION_DAYS=14 deploy/scripts/backup/pg-backup.sh >> /var/log/zeal-backup.log 2>&1
sudo deploy/scripts/backup/pg-backup.sh   # primera corrida a mano; debe listar dos .dump
sudo deploy/scripts/backup/pg-restore-test.sh wellbeing   /var/backups/zeal/wellbeing_<fecha>.dump
sudo deploy/scripts/backup/pg-restore-test.sh marketplace /var/backups/zeal/marketplace_<fecha>.dump
```

## 4. Nodo de medios (LiveKit + coturn)

Certificado TLS de `turn.<dominio>` (coturn atiende TLS en 443):
```bash
sudo apt-get install -y certbot
# Abrir temporalmente 80/tcp en nsg-media, luego:
sudo certbot certonly --standalone -d turn.<dominio> --agree-tos -m <correo-del-equipo>
sudo mkdir -p /etc/zeal/turn-certs
sudo cp /etc/letsencrypt/live/turn.<dominio>/fullchain.pem /etc/zeal/turn-certs/turn.crt
sudo cp /etc/letsencrypt/live/turn.<dominio>/privkey.pem  /etc/zeal/turn-certs/turn.key
sudo chmod 644 /etc/zeal/turn-certs/*      # coturn corre como nobody
# Cerrar de nuevo 80/tcp. Renovación: hook de certbot que copie los archivos y reinicie coturn.
```
```bash
cd /opt/zeal/zeal-infra-compose/deploy/nodes/media
cp .env.example .env && nano .env           # PRIVATE_IP, PUBLIC_IP, TURN_DOMAIN, TURN_SECRET, LIVEKIT_*
docker compose up -d && docker compose ps
```
**Verificar (DT-6):** desde un portátil del equipo, en una red que **bloquee UDP**:
`TURN_HOST=turn.<dominio> TURN_TLS_PORT=443 TURN_SECRET=<secreto> ./tools/turn-check/turn-check.sh` → TCP y TLS en OK.

## 5. Nodo de monitoreo

```bash
cd /opt/zeal/zeal-infra-compose/deploy/nodes/monitoring
cp .env.example .env && nano .env           # IPs, PUBLIC_URL, GRAFANA_ADMIN_PASSWORD
nano alertmanager.yml                       # URL real del canal del equipo (Teams/Discord/Slack o correo)
./render-targets.sh && docker compose up -d
```
Agente en **cada** nodo (incluido este): `cd deploy/nodes/monitoring && docker compose -f monitoring-agent.yml --env-file <(printf 'PRIVATE_IP=%s\nLOKI_URL=http://10.20.5.4:3100/loki/api/v1/push\n' <IP privada>) up -d`

**Verificar:** `curl -s 10.20.5.4:9090/api/v1/targets | jq '.data.activeTargets[] | {job: .labels.job, health}'`
(los servicios aparecerán `up` después del paso 6).

## 6. Nodos de servicios — services-1 y luego services-2

```bash
cd /opt/zeal
cp zeal-infra-compose/deploy/nodes/services/docker-compose.yml docker-compose.yml
cp zeal-infra-compose/deploy/nodes/services/.env.example .env && nano .env
#   NODE_NAME=services-1 (o -2), PRIVATE_IP, DATA_NODE_IP=10.20.3.4, PUBLIC_URL, GHCR_OWNER,
#   *_TAG con el SHA a desplegar, secretos, OIDC_* (paso 9) y DEMO_DATA_ENABLED=false
docker compose pull && docker compose up -d
docker compose ps                                     # healthy (las migraciones corren en el primero que arranque)
for p in 8081 8082 8083 8084; do curl -s localhost:$p/actuator/health/readiness; echo; done
```
Repetir en services-2 **después** de que services-1 esté *healthy* (Flyway ya migró; el segundo solo verifica).

## 7. Nodo web y borde

```bash
# web
cd /opt/zeal/zeal-infra-compose/deploy/nodes/web && cp .env.example .env && nano .env && docker compose up -d
# edge
cd /opt/zeal/zeal-infra-compose/deploy/nodes/edge && cp .env.example .env && nano .env && docker compose up -d
docker compose logs caddy | grep -i certificate        # certificado de zeal.<dominio> obtenido
```
**Verificar:**
```bash
curl -s https://zeal.<dominio>/gateway/health                      # {"status":"UP"}
curl -s -o /dev/null -w '%{http_code}\n' https://zeal.<dominio>/actuator/prometheus   # 404 (no se expone)
for i in $(seq 1 10); do curl -s -o /dev/null https://zeal.<dominio>/api/talleres; done
docker compose logs api-gateway | jq -r .upstream | sort | uniq -c  # tráfico repartido entre 10.20.2.4 y .5
```

## 8. GitHub: pipeline, SonarCloud y protección de main

Ver `CHECKLIST_COWORK.md` (secciones R2-6, R2-18, R2-20). Resumen:
1. En cada repo de servicio: entorno **production** con revisores, secretos `DEPLOY_SSH_KEY`,
   `DEPLOY_KNOWN_HOSTS` (`ssh-keyscan <IP edge>` + claves de host de services-1/2), `BASTION_HOST`,
   `SERVICES_1_HOST=10.20.2.4`, `SERVICES_2_HOST=10.20.2.5`; `SONAR_TOKEN` a nivel de organización.
2. Llave pública `zeal_deploy.pub` en `~deploy/.ssh/authorized_keys` del borde y de los dos nodos de servicios.
3. Primera ejecución: `Actions → Deploy → Run workflow` en wellbeing. Debe desplegar services-1, esperar
   readiness y recién entonces services-2. Repetir para marketplace y realtime-gateway.

## 9. Microsoft Entra ID (R2-17)

1. *App registrations → New registration*: "ZEAL", cuentas de **este** directorio (single tenant).
2. *Redirect URI (Web)*: `https://zeal.<dominio>/api/auth/microsoft/callback`.
3. *Certificates & secrets*: secreto de cliente (24 meses) → `OIDC_CLIENT_SECRET`.
4. *Token configuration*: agregar el claim opcional `email` al ID token.
5. En el `.env` de services-1 y services-2: `OIDC_ISSUER_URI=https://login.microsoftonline.com/<tenant-id>/v2.0`,
   `OIDC_CLIENT_ID=<application id>`, `OIDC_CLIENT_SECRET=…` → `docker compose up -d wellbeing` (uno a la vez).
6. Las cuentas precargadas deben tener el mismo correo que en Entra ID (tabla `user_accounts`).

## 10. Verificación final (con el generador de carga en una máquina distinta)

| Prueba | Comando (desde la máquina de carga, con `ZEAL_API=https://zeal.<dominio>`) | Evidencia |
|---|---|---|
| Login real (SEG-2) | iniciar sesión en el SPA con una cuenta de prueba; luego con una no registrada | `SEG.md` |
| Robo de sesión (SEG-4) | `tests/security/seg4-session-theft.sh` adaptado a las IPs privadas (desde el borde) | `SEG.md` |
| Caída de réplica (DISP-1) | `tests/k6/disp-load.js` + `docker kill` del proceso en services-1 (ver `tests/disp/lib.sh`, `crash()`) | `DISP.md` |
| Escalado (DISP-2) | agregar un tercer nodo/réplica y su registro A en `zeal.internal` | `DISP.md` |
| REND-1 / REND-2 / estrés | `tests/k6/rend1-broadcast.js`, `rend2-applications.js`, `rend-stress.js` | `REND.md` |
| Alertas (OBS-1, SEG-4) | detener PostgreSQL de marketplace 3 min con carga; reutilizar un refresh token | `OBS.md` |
| Relé TURN (DT-6) | `tools/turn-check/turn-check.sh` y `tools/turn-check/index.html` desde red sin UDP | `HU-DT-02.md` |

Completar las plantillas de "ejecución oficial" de cada archivo de `docs/evidencias/`.

## 11. Plan de reversión

| Situación | Acción |
|---|---|
| Una versión nueva de un servicio no queda lista | El pipeline ya revierte el nodo y aborta antes del segundo (`deploy-service.sh`). A mano: en el nodo, `*_TAG=<SHA anterior>` en `.env` y `docker compose up -d <servicio>` |
| Migración de base con problemas | Restaurar el respaldo previo (`pg-restore.sh <base> <archivo> --yes`) con los servicios de esa base detenidos; volver los dos nodos de servicios al SHA anterior |
| Login con Microsoft falla en producción | Revisar `security_audit` (detalle del fallo) y `OIDC_*`; no hay vuelta a contraseñas (se retiraron) |
| El borde falla | `docker compose up -d` en el borde; si es la VM, la SPA y la API quedan sin entrada: recrear desde `provision.sh` (solo `vm edge`) |
| Volver al despliegue de un solo servidor | La VM de la demo con `docker-compose.prod.yml` sigue siendo válida: apuntar el DNS de vuelta a ella |

Al terminar: marcar las casillas de `CHECKLIST_COWORK.md`, guardar los resultados en `docs/evidencias/`
y apagar lo que no se use (las VMs cuestan aunque estén ociosas).
