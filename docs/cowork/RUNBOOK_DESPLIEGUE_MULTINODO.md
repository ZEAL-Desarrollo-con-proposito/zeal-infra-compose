# Runbook · Despliegue de ZEAL en Azure con 4 cuentas — cada microservicio en dos VMs (principal y respaldo)

**Tareas:** R2-4, R2-5, R2-6, DT-5, R2-17, R2-18/R2-20, R2-33, SEG-1 · **Decisiones:** ADR-12, ADR-13, ADR-15
Todo está preparado y validado en local (sintaxis de Compose y NGINX, scripts, y un ensayo real de
apagar una máquina con carga encima). **Nada se ejecutó contra Azure.**

## Qué se despliega

Los 5 componentes que despliega el equipo: **wellbeing**, **marketplace**, **realtime-gateway**, el **front** y la
**infraestructura** (`zeal-infra-compose`: balanceador, datos, medios y monitoreo). Cada microservicio y el front
corren en **dos máquinas virtuales distintas**: una principal (`-1`) y una de respaldo (`-2`), las dos encendidas
y detrás del balanceador del borde.

| VM | Qué corre | Puerto | Carpeta |
|---|---|---|---|
| `edge` | Caddy (HTTPS) + NGINX (balanceador) + CrowdSec | 80/443 | `deploy/nodes/edge` |
| `web-1`, `web-2` | SPA (imagen del repo del front) | 80 | `deploy/nodes/web` |
| `wellbeing-1`, `wellbeing-2` | wellbeing (1 réplica por VM) | 8081 | `deploy/nodes/wellbeing` |
| `marketplace-1`, `marketplace-2` | marketplace | 8082 | `deploy/nodes/marketplace` |
| `realtime-1`, `realtime-2` | realtime-gateway | 8083 | `deploy/nodes/realtime` |
| `data` | PostgreSQL ×2, Redis, RabbitMQ, respaldos | 5432, 5433, 6379, 61613 | `deploy/nodes/data` |
| `media` | LiveKit + coturn | 443, 3478, 7881, UDP | `deploy/nodes/media` |
| `monitoring` | Prometheus, Loki, Grafana, Alertmanager, métricas de negocio | 3000, 3100 | `deploy/nodes/monitoring` |

### Qué pasa cuando se apaga una máquina

El balanceador reparte con `least_conn` entre la VM 1 y la VM 2 de cada servicio. Si una deja de responder
(se apaga, se desasigna, se cae), tras 3 fallos en 10 s la saca de la rotación y manda todo a la otra; las
peticiones de lectura en curso se reintentan en la que queda, sin que la persona vea un error. Cuando la
máquina vuelve, entra sola. **Sirve para apagar cualquiera de estas: `wellbeing-*`, `marketplace-*`, `realtime-*`
y `web-*`.**

Las VMs de infraestructura **no** tienen respaldo: `edge` (entrada), `data` (bases de datos), `media` (video) y
`monitoring`. Si se apaga `data` o `edge`, el sistema completo queda sin servicio. Para la prueba de "apagar una
máquina" usen una VM de servicio o del front (paso 11).

`UPSTREAM_2_FLAG` en el `.env` del borde elige el modo: **vacío** (por defecto) = las dos VMs trabajan y
reparten la carga; **`backup`** = la VM 2 es un respaldo estricto que solo recibe tráfico cuando la 1 falla.

### Reparto entre las 4 cuentas (4 vCPU por cuenta: 16 en total)

Cada VM principal y su respaldo están en **cuentas distintas**: así, aunque una cuenta se quede sin crédito o
sin acceso, el servicio sigue.

| Cuenta | Integrante | VMs (vCPU) |
|---|---|---|
| 1 | _____________ | `edge` (2) + `web-1` (1) + `wellbeing-1` (1) |
| 2 | _____________ | `data` (2) + `marketplace-1` (1) + `realtime-1` (1) |
| 3 | _____________ | `monitoring` (2) + `web-2` (1) + `wellbeing-2` (1) |
| 4 | _____________ | `media` (2) + `marketplace-2` (1) + `realtime-2` (1) |

Tamaños: VMs de servicios `Standard_B1ms` (1 vCPU, 2 GB; una réplica de 1 GB), `web` B1s, `edge`/`media`/`monitoring`
B2s y `data` B2ms. Si su cuota permite más, `SERVICE_SIZE=Standard_B2s` da holgura. **Usen la misma región en las
4 cuentas** (si no, las consultas a la base cruzan regiones y todo se vuelve lento).

### Cómo se hablan las VMs (cuentas distintas)

No hay red privada compartida: las VMs se hablan por su **IP pública estática**, y cada VM abre cada puerto
**solo a las IP de las VMs que lo necesitan** (reglas del NSG que crea `provision-account.sh reglas`).
En todos los `.env`, donde diga "IP de la VM de datos / del borde / …" se pone **su IP pública**; `PRIVATE_IP`
es siempre la IP **privada propia** de esa VM (Azure traduce la pública a esa privada).

Exposición aceptada por el equipo: PostgreSQL, Redis y RabbitMQ escuchan en una IP pública, protegidos por el
firewall (solo las VMs de los servicios) y sus contraseñas. **Ningún secreto ni IP real va en el repositorio**:
todo va en archivos `.env`/`peers.env` (en `.gitignore`) y en los secretos de GitHub.

## 0. Antes de empezar

- [ ] **El front debe estar en `main` con el login de Microsoft** (HU-FE-20, PR #39) y publicar su imagen en GHCR
      (PR #38). Contrato: `docs/contratos/auth-microsoft.md`.
- [ ] Cada integrante: cuenta de Azure con cuota de 4 vCPU en la región elegida y Azure CLI (`az login`).
- [ ] Dominio con acceso al DNS: `zeal.<dominio>` (borde) y `turn.<dominio>` (medios).
- [ ] Cada integrante una llave SSH para administrar (`ssh-keygen -t ed25519 -f ~/.ssh/zeal_admin`) y **una llave
      solo para el pipeline** (`ssh-keygen -t ed25519 -N "" -f ~/.ssh/zeal_deploy`; la privada va solo en el secreto
      de GitHub, nunca en el repo).
- [ ] Los repos con el Sprint 2 en `main` (los workflows publican las imágenes desde `main`).
- [ ] **Secretos generados una sola vez**, guardados en el gestor de contraseñas del equipo y compartidos por
      un canal seguro (no por el chat del grupo en claro):
  ```bash
  for s in JWT_SECRET REDIS_PASSWORD RABBITMQ_PASSWORD TURN_SECRET LIVEKIT_API_SECRET CROWDSEC_BOUNCER_KEY \
           WELLBEING_DB_OWNER_PASSWORD WELLBEING_DB_APP_PASSWORD MARKETPLACE_DB_OWNER_PASSWORD \
           MARKETPLACE_DB_APP_PASSWORD GRAFANA_ADMIN_PASSWORD; do echo "$s=$(openssl rand -hex 32)"; done
  ```
  `JWT_SECRET` es **el mismo** en wellbeing, marketplace y realtime. Sin comillas simples en las contraseñas de base.

## 1. Crear las VMs y abrir los puertos (≈ 30 min; cada integrante en su cuenta)

```bash
git clone https://github.com/<organizacion>/zeal-infra-compose.git && cd zeal-infra-compose/deploy/azure
az login
export RG=rg-zeal LOCATION=eastus2 OFFICE_CIDR=<tu IP pública>/32 SSH_KEY=~/.ssh/zeal_admin.pub
```
Cada integrante crea **solo las VMs de su cuenta** (ejemplo, cuenta 1):
```bash
./provision-account.sh crear edge web-1                       # SSH solo desde tu IP
SSH_FROM=Internet ./provision-account.sh crear wellbeing-1    # VMs de servicios: SSH por llave desde Internet (pipeline)
```
> Las VMs de servicios necesitan `SSH_FROM=Internet` para que GitHub Actions entre; solo aceptan llave (Azure
> desactiva la contraseña por defecto). Las demás VMs: solo desde la IP de quien administra.

Cada comando imprime la **IP pública** y la **IP privada** de cada VM. Todos las pegan en el grupo y **cada uno
completa su copia de `deploy/azure/peers.env`** (copiar de `peers.env.example`) con las 12 IP públicas. Luego cada
integrante abre los puertos de sus VMs:
```bash
./provision-account.sh reglas edge web-1 wellbeing-1
```
DNS público: `A zeal.<dominio> → IP de edge` y `A turn.<dominio> → IP de media`.
**Verificar:** `az network nsg rule list -g rg-zeal --nsg-name nsg-wellbeing-1 -o table` muestra el puerto 8081 solo
para las IP de `edge` y `monitoring`.

## 2. Preparar cada VM (cada integrante en las suyas)

```bash
ssh -i ~/.ssh/zeal_admin deploy@<IP pública de la VM>
sudo apt-get update && sudo apt-get install -y docker.io docker-compose-v2 git jq curl
sudo usermod -aG docker deploy && newgrp docker
sudo mkdir -p /opt/zeal && sudo chown deploy: /opt/zeal && cd /opt/zeal
git clone https://github.com/<organizacion>/zeal-infra-compose.git
# VMs que bajan imágenes privadas (wellbeing, marketplace, realtime, web):
echo "<token de GitHub con read:packages>" | docker login ghcr.io -u <usuario> --password-stdin
```
Pipeline: agregar `zeal_deploy.pub` a `~/.ssh/authorized_keys` de las 6 VMs de servicios.

## 3. VM de datos — primero, todo depende de ella

```bash
cd /opt/zeal/zeal-infra-compose/deploy/nodes/data
cp .env.example .env && nano .env        # PRIVATE_IP (privada propia) y los secretos de bases, Redis y RabbitMQ
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
sudo mkdir -p /var/backups/zeal && sudo crontab -e      # agregar:
15 3 * * * cd /opt/zeal/zeal-infra-compose && BACKUP_DIR=/var/backups/zeal deploy/scripts/backup/pg-backup.sh >> /var/log/zeal-backup.log 2>&1
sudo deploy/scripts/backup/pg-backup.sh && ls /var/backups/zeal                 # primera corrida: dos .dump
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

## 5. Publicar las imágenes (GitHub)

En cada repo de servicio (wellbeing, marketplace, realtime-gateway): **Actions → Deploy → Run workflow**. El job
`publish` sube `ghcr.io/<organizacion>/zeal-<servicio>:<sha>` y `:latest`. El job `deploy` fallará hasta
completar el paso 9: es lo esperado. Para el front: su workflow "Publicar imagen" ya la deja en GHCR.

## 6. Las seis VMs de microservicios (principal y respaldo)

Mismo procedimiento en cada una; **wellbeing primero** (realtime depende de él), y la VM 1 antes que la 2:

```bash
SERVICIO=wellbeing            # o marketplace, o realtime
cd /opt/zeal
cp zeal-infra-compose/deploy/nodes/$SERVICIO/docker-compose.yml docker-compose.yml
cp zeal-infra-compose/deploy/nodes/$SERVICIO/.env.example .env && nano .env
docker compose pull && docker compose up -d && docker compose ps      # "healthy" en ≈ 1 min
```
En el `.env`: `NODE_NAME=<servicio>-1` (o `-2` en el respaldo), `PRIVATE_IP` = IP privada **propia** y las demás IP
son **públicas**:

| VM | Qué completar |
|---|---|
| wellbeing-1/2 | `DATA_NODE_IP`, `GHCR_OWNER`, `PUBLIC_URL`, `JWT_SECRET`, `REDIS_PASSWORD`, `DB_OWNER_PASSWORD`/`DB_APP_PASSWORD` (los de **wellbeing**), `TURN_URLS`, `TURN_SECRET`, `LIVEKIT_*`, `OIDC_*` (paso 8) |
| marketplace-1/2 | `DATA_NODE_IP`, `GHCR_OWNER`, `PUBLIC_URL`, `JWT_SECRET`, `REDIS_PASSWORD`, `DB_OWNER_PASSWORD`/`DB_APP_PASSWORD` (los de **marketplace**), `LIVEKIT_*` |
| realtime-1/2 | `DATA_NODE_IP`, `EDGE_NODE_IP`, `GHCR_OWNER`, `PUBLIC_URL`, `JWT_SECRET`, `REDIS_PASSWORD`, `RABBITMQ_PASSWORD` |

Las dos VMs de un microservicio llevan **el mismo `.env`** salvo `NODE_NAME` y `PRIVATE_IP`.
**Verificar** (en cada VM): `curl -s localhost:8081/actuator/health/readiness` (8082 / 8083) → `{"status":"UP"}`.

## 7. VMs web y borde

```bash
# web-1 y web-2
cd /opt/zeal/zeal-infra-compose/deploy/nodes/web && cp .env.example .env && nano .env && docker compose up -d

# borde
cd /opt/zeal/zeal-infra-compose/deploy/nodes/edge && cp .env.example .env && nano .env
#   WELLBEING_1_HOST/_2_HOST, MARKETPLACE_…, REALTIME_…, FRONTEND_1_HOST/_2_HOST, LIVEKIT_HOST, MONITORING_NODE_IP
#   (IP públicas), SITE_ADDRESS, CROWDSEC_BOUNCER_KEY y UPSTREAM_2_FLAG (vacío = activo-activo)
docker compose up -d && docker compose ps
docker compose logs caddy | grep -i certificate          # certificado de zeal.<dominio> obtenido
docker compose exec crowdsec cscli bouncers list         # el balanceador (nginx) aparece consultando
```
**Verificar:**
```bash
curl -s https://zeal.<dominio>/gateway/health                                           # {"status":"UP"}
curl -s -o /dev/null -w '%{http_code}\n' https://zeal.<dominio>/actuator/prometheus    # 404: no se expone
for i in $(seq 1 20); do curl -s -o /dev/null https://zeal.<dominio>/api/talleres; done
docker compose logs api-gateway | grep '^{' | jq -r .upstream | sort | uniq -c           # tráfico en las dos VMs
docker compose logs api-gateway | grep '^{' | tail -1 | jq .remoteAddr                    # IP REAL del cliente (no la de Caddy)
```

## 8. Microsoft Entra ID (login)

1. *App registrations → New registration*: "ZEAL", cuentas de este directorio.
2. *Redirect URI (Web)*: `https://zeal.<dominio>/api/auth/microsoft/callback`.
3. *Certificates & secrets*: secreto de cliente → `OIDC_CLIENT_SECRET`.
4. *Token configuration*: agregar el claim opcional `email` al ID token.
5. En el `.env` de **wellbeing-1 y wellbeing-2**: `OIDC_ISSUER_URI=https://login.microsoftonline.com/<tenant-id>/v2.0`,
   `OIDC_CLIENT_ID`, `OIDC_CLIENT_SECRET` → `docker compose up -d` (una VM a la vez).
6. Los correos de `user_accounts` deben coincidir con los de Entra ID; con `DEMO_DATA_ENABLED=false` solo existen
   las cuentas de las migraciones: cargar las reales antes de la demostración.

## 9. Pipeline de despliegue (GitHub)

En **cada** repo de servicio: *Settings → Environments → production* con estos secretos:

| Secreto | Valor |
|---|---|
| `DEPLOY_SSH_KEY` | contenido de `~/.ssh/zeal_deploy` (la privada) |
| `DEPLOY_KNOWN_HOSTS` | `ssh-keyscan <IP de la VM 1> <IP de la VM 2>` |
| `SERVICE_1_HOST` | IP pública de la VM 1 de **ese** microservicio |
| `SERVICE_2_HOST` | IP pública de la VM 2 (respaldo) |

**Probar:** *Actions → Deploy → Run workflow*. Despliega la VM 1, espera su readiness y **solo entonces** la VM 2;
si la 1 no queda lista, vuelve a la versión anterior, falla y no toca la 2. El front se actualiza con
`docker compose pull && docker compose up -d` en `web-1` y luego en `web-2`.
SonarCloud y protección de `main`: `CHECKLIST_COWORK.md` (R2-18, R2-20).

## 10. VM de monitoreo

```bash
cd /opt/zeal/zeal-infra-compose/deploy/nodes/monitoring
cp .env.example .env && nano .env           # IP de las 2 VMs de cada servicio, de las 12 VMs, GRAFANA_ADMIN_PASSWORD, REDIS_PASSWORD
nano alertmanager.yml                       # webhook real del equipo (Teams/Discord/Slack) o correo
./render-targets.sh && docker compose up -d --build
```
Agente (cAdvisor + envío de logs) en **cada una de las 12 VMs**:
```bash
cd /opt/zeal/zeal-infra-compose/deploy/nodes/monitoring
printf 'PRIVATE_IP=%s\nLOKI_URL=http://<IP pública de monitoring>:3100/loki/api/v1/push\n' <IP privada de esta VM> > agent.env
docker compose -f monitoring-agent.yml --env-file agent.env up -d
```
**Verificar:** `https://zeal.<dominio>/grafana` pide login y el tablero "ZEAL · Estado de la plataforma" muestra las
dos réplicas de cada servicio arriba.

## 11. Prueba de apagar una máquina (la que piden en la evaluación)

Con todo funcionando y una carga ligera (por ejemplo, el SPA abierto o `tests/k6/disp-load.js` desde otra máquina):

```bash
# 1. Mirar el reparto: tráfico en las dos VMs de wellbeing
docker compose -f deploy/nodes/edge/docker-compose.yml logs --since 1m api-gateway | grep '^{' | jq -r .upstream | sort | uniq -c
# 2. Apagar la VM principal de un servicio (en la cuenta que la tiene)
az vm deallocate -g rg-zeal -n vm-zeal-wellbeing-1 --no-wait
# 3. Seguir usando la aplicación: login, directorio, reservar. Debe funcionar sin errores visibles.
#    En el borde, todo el tráfico de wellbeing va ahora a la VM 2:
docker compose logs --since 30s api-gateway | grep '^{' | jq -r '.upstream' | sort | uniq -c
# 4. Volver a encenderla: entra sola a la rotación
az vm start -g rg-zeal -n vm-zeal-wellbeing-1
```
Repetir con `marketplace-1`, `realtime-1` y `web-1`. Durante el apagado, la **primera** petición puede tardar ~2 s
(el balanceador espera a que la VM caída no responda antes de pasar a la otra); las siguientes ya van directo.
Las conexiones de tiempo real (chat, presencia) de quienes estaban en la VM apagada se reconectan solas a la otra
en ~5 s (el front reintenta). **No apagar** `data`, `edge`, `media` ni `monitoring` en esta prueba.

## 12. Verificación final

| Prueba | Cómo | Evidencia |
|---|---|---|
| Login real (SEG-2) | SPA con una cuenta precargada, una no registrada y cancelando en Microsoft | `SEG.md` |
| Fuerza bruta (SEG-1) | `tests/security/seg1-bruteforce.sh` adaptado, desde dos redes distintas | `SEG.md` |
| Caída de una VM (DISP-1) | paso 11 con `tests/k6/disp-load.js` desde otra máquina | `DISP.md` |
| Escalado (DISP-2) | agregar una tercera VM a un servicio: crear la VM, mismo `.env`, y sumarla al borde (requiere una línea más en el template) | `DISP.md` |
| Robo de sesión (SEG-4) | reutilizar un refresh token y consultar las 6 VMs | `SEG.md` |
| REND-1 / REND-2 / estrés | `tests/k6/rend*.js` con `ZEAL_API=https://zeal.<dominio>` | `REND.md` |
| Alertas (OBS-1, SEG-4) | detener PostgreSQL de marketplace 3 min con carga; reutilizar un refresh token | `OBS.md` |
| Relé TURN (DT-6) | `tools/turn-check/` desde una red sin UDP | `HU-DT-02.md` |

## 13. Plan de reversión y límites

| Situación | Acción |
|---|---|
| Una versión nueva no queda lista | `deploy-service.sh` vuelve a la versión anterior y el job falla sin tocar la otra VM. A mano: `IMAGE_TAG=<sha anterior>` en `/opt/zeal/.env` y `docker compose up -d` |
| Migración de base con problemas | Detener las dos VMs del servicio, `pg-restore.sh <base> <archivo> --yes` en `data`, volver al SHA anterior |
| Login con Microsoft falla | Revisar `security_audit` (columna `detail`) y `OIDC_*`. No hay vuelta a contraseñas |
| Se cae/apaga una VM de servicio o web | Automático: el balanceador manda todo a la otra (paso 11) |
| Se cae `edge`, `data`, `media` o `monitoring` | Sin respaldo: recrear/arrancar la VM. Es el límite de este esquema (el siguiente paso sería una segunda VM de `edge` con DNS de dos registros y réplica de PostgreSQL) |
| Una IP legítima queda bloqueada por CrowdSec | `docker compose exec crowdsec cscli decisions delete --ip <ip>` en el borde |

Al terminar: marcar `CHECKLIST_COWORK.md`, guardar resultados en `docs/evidencias/` y **apagar las VMs que no se usen**
(cuestan aunque estén ociosas): `az vm deallocate -g rg-zeal --ids $(az vm list -g rg-zeal --query "[].id" -o tsv)`.
