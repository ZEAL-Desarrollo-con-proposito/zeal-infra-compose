# Runbook · Despliegue en DOS máquinas (A y B) con respaldo mutuo

Alternativa al despliegue de 12 VMs (`RUNBOOK_DESPLIEGUE_MULTINODO.md`): todo corre en **dos máquinas**. Cada una
tiene su balanceador de carga y lleva una copia de los servicios de la otra; si una se apaga, la otra sigue
atendiendo. Lo nuevo vive en `deploy/duo/` y `deploy/azure/provision-duo.sh`. Nada de esto se ha ejecutado contra
Azure: la replicación y el failover de datos sí se ensayaron en local (ver sección 9).

## 1. Qué corre en cada máquina

| | Máquina **A** | Máquina **B** |
|---|---|---|
| Repos que se despliegan allí (reparto acordado) | wellbeing · marketplace · realtime-gateway | front · infra-compose |
| Capa de aplicación (`deploy/duo/app`) | wellbeing, marketplace, realtime, **front (copia)**, NGINX, CrowdSec, Caddy | wellbeing **(copia)**, marketplace **(copia)**, realtime **(copia)**, front, NGINX, CrowdSec, Caddy |
| Datos (`deploy/duo/data`) | **réplica**: PostgreSQL ×2, Redis (en vivo) y RabbitMQ (en espera) | **primaria**: PostgreSQL ×2, Redis, RabbitMQ |
| Medios (`deploy/nodes/media`) | — | LiveKit + coturn |
| Monitoreo (`deploy/nodes/monitoring`) | agente (cAdvisor + logs) | Prometheus, Loki, Grafana, Alertmanager + agente |

Las dos máquinas ejecutan **los mismos contenedores de aplicación** desde las mismas imágenes de GHCR (por eso cada
una no necesita clonar "sus" repos: solo `zeal-infra-compose`). "A tiene 3 repos y B 2" es el reparto de
responsabilidad principal; la copia de respaldo es lo que permite que una cubra a la otra.

```
                Internet ── DNS zeal.<dominio> → IP de A  e  IP de B
                      │                                   │
              ┌───────▼─────── A ───────┐         ┌───────▼─────── B ───────┐
              │ Caddy → NGINX (LB)      │ ◄─────► │ Caddy → NGINX (LB)      │
              │ wellbeing marketplace   │         │ wellbeing marketplace   │
              │ realtime  front         │         │ realtime  front         │
              │ PostgreSQL/Redis RÉPLICA│ ◄─repl──│ PostgreSQL/Redis PRIMARIA│
              └─────────────────────────┘         │ RabbitMQ · LiveKit · Grafana
                                                  └─────────────────────────┘
```

El NGINX de cada máquina reparte (`least_conn`) entre el servicio local y el de la otra máquina y saca de la
rotación al que deja de responder (`max_fails=3 fail_timeout=10s`): **sin intervención**. Con
`UPSTREAM_2_FLAG=backup` la otra máquina solo entra cuando falla ésta (modo respaldo estricto; los WebSockets
siempre se reparten por sesión).

## 2. Qué pasa cuando se apaga una máquina

| Se apaga | Efecto | Qué haces |
|---|---|---|
| **A** (réplica) | El DNS/los clientes usan B; el NGINX de B saca los servicios de A. Los datos no se tocan. **Sin caída** de funciones. | Nada. Al volver, A reanuda la replicación sola. |
| **B** (primaria) | Los clientes llegan a A, que sirve el front, pero **la API, los avisos en vivo y la caché dependen de las bases/Redis/RabbitMQ que estaban en B**: fallan hasta promover la réplica. LiveKit (video) y Grafana también estaban en B. | En A: `deploy/duo/scripts/promote.sh` (≈ 1–2 min; ver 9.2). Después todo vuelve, salvo el **video** hasta que B regrese (limitación conocida). |

Honestidad sobre los límites:
- **Failover de datos con un comando, no automático.** Es deliberado: promover sola una réplica ante un corte de red
  puede dejar dos primarios. `promote.sh` se niega si el primario aún responde.
- La replicación de PostgreSQL es **asíncrona**: si B se apaga de golpe, pueden perderse los últimos milisegundos de
  commits que no alcanzaron a viajar. Si se apaga ordenadamente (`az vm deallocate`, `shutdown`), Docker detiene
  PostgreSQL y se envía todo el WAL: no se pierde nada confirmado.
- Entre el apagado de B y `promote.sh` la API de A no funciona (sus conexiones a datos apuntan a B): son los 1–2
  minutos de la promoción más lo que tarde alguien en ejecutarla. Es el compromiso de no promover automáticamente.
- LiveKit/coturn y monitoreo no tienen respaldo. El resto de la aplicación sí.

## 3. Dimensionamiento y cuentas de Azure

- **B** es la más cargada (3 JVM + 2 PostgreSQL + Redis + RabbitMQ + LiveKit + monitoreo): `Standard_D4s_v5`
  (4 vCPU / 16 GB) mínimo. **A**: `Standard_D4s_v5` también, para poder cargar con todo si B cae.
- Si su cuota es de 4 vCPU por cuenta, una VM de 4 vCPU por cuenta cabe justo (una cuenta para A y otra para B,
  o ambas en la misma si la cuota lo permite). Si no alcanza, bajen `REPLICA_MEM` a `512m` y usen D2s_v5 solo para
  una prueba ligera, no para REND.
- Discos de 64 GB (los crea el script).

## 4. Antes de empezar

Lo mismo que la sección 0 del runbook multinodo: front en `main` con login de Microsoft y su imagen en GHCR,
dominio con acceso al DNS (`zeal.<dominio>` y `turn.<dominio>`), llaves SSH (administración y pipeline) y los
secretos generados **una sola vez** y compartidos. Se agrega uno más:

```bash
echo "REPL_PASSWORD=$(openssl rand -hex 32)"
```
`JWT_SECRET`, contraseñas de bases/Redis/RabbitMQ, OIDC y LiveKit/TURN deben ser **idénticos en las dos máquinas**.
`CROWDSEC_BOUNCER_KEY` puede ser distinto en cada una.

## 5. Crear las dos máquinas

Cada quien en su cuenta (o la misma persona en la suya):

```bash
cd zeal-infra-compose/deploy/azure
export RG=rg-zeal OFFICE_CIDR=<tu-IP-pública>/32 SSH_FROM=Internet   # Internet: GitHub Actions despliega por llave
./provision-duo.sh crear a        # en la cuenta de A  → imprime IP pública y privada
./provision-duo.sh crear b        # en la cuenta de B
cp peers-duo.env.example peers-duo.env && nano peers-duo.env    # A_IP y B_IP públicas
./provision-duo.sh reglas a
./provision-duo.sh reglas b
```
El script deja 80/443 abiertos a Internet; los puertos de servicios y bases (8080–8083, 3080, 5432/5433, 6379,
61613) solo a la **otra** máquina; en B además TURN/LiveKit y Grafana. Anota: `A_PRIV`, `A_PUB`, `B_PRIV`, `B_PUB`.

## 6. Preparar las dos máquinas

En **A y B**:
```bash
ssh -i ~/.ssh/zeal_admin deploy@<IP pública>
sudo apt-get update && sudo apt-get install -y docker.io docker-compose-v2 git jq curl postgresql-client
sudo usermod -aG docker deploy && newgrp docker
sudo mkdir -p /opt/zeal && sudo chown deploy: /opt/zeal && cd /opt/zeal
git clone https://github.com/<organizacion>/zeal-infra-compose.git
echo "<token de GitHub con read:packages>" | docker login ghcr.io -u <usuario> --password-stdin
```
Pipeline: agregar `zeal_deploy.pub` a `~/.ssh/authorized_keys` de **A y B**.

## 7. Orden de despliegue (la B primero: tiene los datos)

### 7.1 Datos — B (primaria)
```bash
cd /opt/zeal/zeal-infra-compose/deploy/duo/data
cp .env.example .env && nano .env   # COMPOSE_PROFILES=primary, PRIVATE_IP=<B_PRIV>, contraseñas, REPL_PASSWORD
docker compose up -d && docker compose ps            # todo "healthy"
```

### 7.2 Datos — A (réplica)
```bash
cd /opt/zeal/zeal-infra-compose/deploy/duo/data
cp .env.example .env && nano .env   # COMPOSE_PROFILES=replica, PRIVATE_IP=<A_PRIV>, PRIMARY_HOST=<B_PUB>, mismas contraseñas
docker compose up -d && docker compose ps
../scripts/replication-status.sh     # postgres-*-replica: t · redis: role:slave, master_link_status:up
```
En B: `deploy/duo/scripts/replication-status.sh` debe listar la IP de A en cada base (`streaming`).

### 7.3 Medios y monitoreo — solo B
Igual que las secciones 4 y 10 del runbook multinodo, con estas diferencias:
- **coturn comparte máquina con Caddy**, que ya usa el 443: en `deploy/nodes/media/.env` agrega `TURN_TLS_PORT=5349`
  (y `TURN_URLS` de la app ya apunta a `:5349`). Algunas redes muy restrictivas bloquean el 5349 (el 443 era
  para eso); es el precio de compartir máquina.
- `deploy/nodes/monitoring/.env`: `WELLBEING_NODE_IPS="<A_PUB> <B_PRIV>"` (y lo mismo para marketplace y realtime),
  `DATA_NODE_IP=<B_PRIV>`, `ALL_NODE_IPS="<A_PUB> <B_PRIV>"`. Luego `./render-targets.sh && docker compose up -d --build`.
- Agente en A y en B (`monitoring-agent.yml`, con `LOKI_URL=http://<B_PUB>:3100/loki/api/v1/push`).

### 7.4 Aplicación — B y luego A
```bash
cd /opt/zeal/zeal-infra-compose/deploy/duo/app
cp .env.example .env && nano .env
```
| Variable | En B | En A |
|---|---|---|
| `MACHINE` | `b` | `a` |
| `PRIVATE_IP` | `<B_PRIV>` | `<A_PRIV>` |
| `PEER_IP` | `<A_PUB>` | `<B_PUB>` |
| `DATA_HOST` | `<B_PRIV>` | `<B_PUB>` |
| `MEDIA_HOST` / `MONITORING_HOST` | `<B_PRIV>` | `<B_PUB>` |
| `CROWDSEC_BOUNCER_KEY` | `openssl rand -hex 24` | otra distinta |
| resto (`PUBLIC_URL`, `SITE_ADDRESS`, `GHCR_OWNER`, JWT, bases, OIDC, TURN, LiveKit) | iguales | iguales |

```bash
docker compose pull && docker compose up -d && docker compose ps
curl -s localhost:8080/gateway/health          # en cada máquina (por su IP privada si no responde en localhost)
```
Los servicios arrancan en cualquiera de las dos máquinas (Flyway migra una sola vez, con bloqueo, contra la base de B).

### 7.5 DNS y HTTPS
Crea **dos registros A** `zeal.<dominio>` → `<A_PUB>` y `<B_PUB>`, y `turn.<dominio>` → `<B_PUB>`. Los navegadores
prueban la otra IP si una no responde (failover del lado del cliente en segundos; reduce el TTL a 60 s). Para un
cambio más rápido puedes poner Azure Traffic Manager (prioridad o ponderado) con chequeo de salud en
`/gateway/health`; no lo hemos configurado.

**Certificado:** cada Caddy pide su propio certificado a Let's Encrypt, que valida llegando a *una* de las dos IP;
con DNS de dos IP la validación cae en la otra máquina la mitad de las veces. Caddy reintenta solo, pero para que
salga a la primera: (1) crea el DNS con **solo la IP de B** y arranca Caddy en B hasta ver el certificado en
`docker compose logs caddy`; (2) cambia el DNS a **solo la IP de A**, arranca Caddy en A y espera su certificado;
(3) deja las dos IP. La renovación (cada ~60 días) usa el mismo mecanismo y se reintenta a diario.

## 8. Microsoft Entra ID y pipeline

Entra ID: sección 8 del runbook multinodo, con una sola URL de redirección `https://zeal.<dominio>/api/auth/microsoft/callback`
y el `.env` de **A y B** (una máquina a la vez).

Pipeline (cada repo de servicio → *Environments → production*): `DEPLOY_SSH_KEY`, `DEPLOY_KNOWN_HOSTS`
(`ssh-keyscan <A_PUB> <B_PUB>`), **`SERVICE_1_HOST=<A_PUB>`**, **`SERVICE_2_HOST=<B_PUB>`**. Los workflows
actualizan **A, esperan el readiness y solo entonces B** (si A no queda lista, vuelve a la versión anterior y no toca B).
`deploy-service.sh` reconoce `deploy/duo/app` y actualiza solo la etiqueta de ese servicio
(`WELLBEING_TAG`, `MARKETPLACE_TAG` o `REALTIME_TAG`).
El front se actualiza a mano, primero en una máquina y luego en la otra:
`cd /opt/zeal/zeal-infra-compose/deploy/duo/app && docker compose pull frontend && docker compose up -d frontend`.

## 9. Prueba de apagar una máquina

### 9.1 Apagar A (sin caída)
```bash
az vm deallocate -g rg-zeal -n vm-zeal-a            # carga: tests/k6/disp-load.js desde otra máquina
curl -s https://zeal.<dominio>/gateway/health       # sigue 200 (B atiende todo)
az vm start -g rg-zeal -n vm-zeal-a                 # A vuelve, la réplica se pone al día sola
```
En el balanceador de B, A reaparece en la rotación sola cuando responde de nuevo.

### 9.2 Apagar B (con failover de datos)
1. `az vm deallocate -g rg-zeal -n vm-zeal-b`. Los clientes pasan a A (el front carga; la API falla hasta el paso 2).
2. **En A:** `cd /opt/zeal/zeal-infra-compose/deploy/duo/scripts && ./promote.sh` (escribe `PROMOVER`). Promueve
   PostgreSQL y Redis, apunta wellbeing/marketplace/realtime a las bases locales y los reinicia (≈ 1–2 min).
3. Comprueba: crear una cita o postular a una convocatoria en la web. El video (LiveKit) no estará disponible.
4. **Al volver B:** *no* la conectes a los servicios. En B: `./rejoin-as-replica.sh <A_PUB>` (borra los datos
   viejos de B y los copia de A; B queda como réplica y sus servicios apuntan a A). Dejar a A como primaria es válido;
   para volver al reparto original, repite el procedimiento en una ventana de mantenimiento.

### 9.3 Qué se ensayó en local (y qué no)
- ✅ Replicación en vivo de PostgreSQL y Redis desde una base real; `promote.sh` con el primario caído: escrituras
  tras promover, datos intactos, y la réplica promovida **sigue primaria tras reiniciar** (PostgreSQL y Redis).
- ✅ El reparto entre las dos máquinas, la salida de la rotación y la vuelta sola de una VM: el mismo balanceador
  se ensayó con `tests/disp/vm-failover.sh` (0 errores en modo activo).
- ⚠ **No** se ensayó de punta a punta `rejoin-as-replica.sh`, ni el flujo completo con las máquinas reales en Azure.
  Ensáyenlo antes de la demostración: es la parte con más riesgo de cometer un error humano.

## 10. Verificación final

- [ ] `docker compose ps` de app y datos: todo `healthy` en A y B.
- [ ] `replication-status.sh`: B lista la réplica de A; A está en recuperación (`t`).
- [ ] `https://zeal.<dominio>` carga con HTTPS desde las dos IP (`curl --resolve zeal.<dominio>:443:<A_PUB> …` y `<B_PUB>`).
- [ ] Login con Microsoft, publicar una convocatoria como administradora, postular como empleado y ver el aviso en vivo.
- [ ] Grafana (`/grafana`): las réplicas de A y B de cada servicio aparecen arriba.
- [ ] 9.1 y 9.2 ejecutadas con carga y con resultados guardados en `docs/evidencias/DISP.md`.
- [ ] REND-1/REND-2 con k6 desde una tercera máquina (`docs/evidencias/REND.md`).

## 11. Reversión y límites
- Volver a una versión anterior: en el `.env` de la máquina, `<SERVICIO>_TAG=<sha anterior>` y
  `docker compose up -d <servicio>`; una máquina a la vez.
- Si la réplica se corrompe o se queda atrás: en esa máquina `docker compose down -v` y `up -d` en rol `replica`
  vuelve a clonar desde el primario.
- Respaldos de PostgreSQL: `deploy/scripts/backup/pg-backup.sh` en B (la primaria), como en el runbook multinodo.
- Una sola región, y sin respaldo para LiveKit/coturn/monitoreo: límite aceptado de este diseño de dos máquinas.
