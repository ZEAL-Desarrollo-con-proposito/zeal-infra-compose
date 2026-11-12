# Guía paso a paso del backend de ZEAL (Sprint 2)

**Estado:** al día con la Fase 1 (deuda técnica) y la Fase 2 (segundo release) · noviembre de 2026
**Para:** quien llega al proyecto y necesita levantar, probar y desplegar el backend sin adivinar rutas ni puertos.
La versión del MVP quedó como `GUIA_PASO_A_PASO_BACKEND.v1-mvp.md` (histórico).

---

## 1. Qué hay y dónde

| Repositorio | Qué es | Puerto | Base / broker |
|---|---|---|---|
| `zeal-wellbeing-service` | Wellbeing Domain: psicólogos, franjas, reservas, sala 1:1 (LiveKit), chat; **login con Microsoft y sesiones** | 8081 | PostgreSQL `zeal_wellbeing_db` (esquema `wellbeing`), Redis |
| `zeal-marketplace-service` | Business Domain: convocatorias (cupos y lista de espera), talleres en vivo (LiveKit) | 8082 | PostgreSQL `zeal_marketplace_db` (esquema `marketplace`), Redis |
| `zeal-realtime-gateway` | WebSocket/STOMP (SockJS): notificaciones, presencia, chat, avisos de cupos y franjas; telemetría del cliente | 8083 | Redis + **RabbitMQ (STOMP)** |
| `zeal-infra-compose` | Docker Compose (local, un servidor, multinodo), NGINX, Caddy, coturn, LiveKit, monitoreo, pruebas, docs; **`services/zeal-business-metrics`** (consumidor de eventos, 8084) | — | — |

```
Navegador ──HTTPS──▶ Caddy ──▶ NGINX :8080 ─┬─▶ wellbeing ×2 ──┬─▶ PostgreSQL wellbeing
   │                            (balanceo)    ├─▶ marketplace ×2 ─┼─▶ PostgreSQL marketplace
   │                                          ├─▶ realtime ×2 ────┼─▶ RabbitMQ (STOMP relay)
   │                                          └─▶ SPA             └─▶ Redis (eventos, presencia, lista negra, caché)
   └── WebRTC/TURN ─▶ LiveKit + coturn          Prometheus · Loki · Grafana · Alertmanager (monitoreo)
```

Integración entre servicios: **eventos por Redis Pub/Sub** (después del commit, con `eventId`,
`commitTimestamp` y `correlationId`) y llamadas REST del gateway a wellbeing con el token de la persona.
Ningún servicio guarda estado en memoria: cualquier réplica atiende cualquier petición.

## 2. Requisitos

- Docker 24+ con Compose v2 (en Linux las pruebas usan las IPs de los contenedores).
- Java 21+ y el Maven Wrapper de cada repo (`./mvnw`), solo para compilar o depurar en el host.
- Node 20+ (scripts de `tests/`), opcional k6 (se usa la imagen `grafana/k6:1.4.2`).
- Los cinco repositorios clonados como hermanos: `~/ProjectZEAL/zeal-*`.

## 3. Levantar el entorno local (2 réplicas de cada servicio)

```bash
cd zeal-infra-compose
cp .env.example .env                      # opcional: todo tiene valores de desarrollo
./coturn/generate-dev-cert.sh             # certificado autofirmado para TURN por TLS (una vez)
docker compose up -d --build              # bases, Redis, RabbitMQ, LiveKit, coturn, mock OIDC, 2×3 servicios, NGINX
docker compose ps                         # esperar "healthy" en todo (≈ 1-2 min)
curl -s localhost:8080/gateway/health     # {"status":"UP"}

# Con monitoreo (Prometheus, Loki, Alloy, Grafana, Alertmanager, exportadores y el consumidor de métricas):
docker compose -f docker-compose.yml -f docker-compose.monitoring.yml up -d --build
```

| URL local | Para qué |
|---|---|
| `http://localhost:8080` | API Gateway (NGINX): **única entrada** del frontend (`VITE_API_BASE_URL`) |
| `http://localhost:8090` | Proveedor OIDC de prueba (en lugar de Microsoft) |
| `http://localhost:3001` | Grafana (admin / `GRAFANA_ADMIN_PASSWORD`, por defecto `zeal-dev-grafana`) |
| `http://localhost:9090` · `:9093` | Prometheus · Alertmanager |
| `http://localhost:15672` | Consola de RabbitMQ (zeal / `RABBITMQ_PASSWORD`) |
| `localhost:5432` · `:5433` · `:6379` · `:61613` | PostgreSQL wellbeing · marketplace · Redis · RabbitMQ STOMP (para depurar) |

**Escalar en caliente:** `docker compose up -d --no-recreate --scale marketplace=3 marketplace` — NGINX la
descubre por DNS en segundos, sin recargarse.

**Depurar un servicio en el host:** `docker compose -f docker-compose.yml -f docker-compose.host-dev.yml up -d`
(solo infraestructura, NGINX apuntando a `host.docker.internal`) y `./mvnw spring-boot:run` en cada repo.

**Empezar de cero:** `docker compose down -v` (borra las bases y los datos de demostración, que se
vuelven a sembrar con fechas relativas al arranque).

## 4. Iniciar sesión en local

ZEAL ya no tiene contraseñas (R2-17): el login es con Microsoft y en local con el proveedor de prueba.

1. El SPA llama `POST /api/auth/microsoft {remember, returnTo}` y navega a la `authorizationUrl`.
2. En `http://localhost:8090` escribe cualquier usuario y, en *claims*, el correo de una cuenta semilla:
   `{"email": "david.cajamarca@nexura.co"}`.
3. Vuelve al SPA con la cookie de renovación; el SPA llama `POST /api/auth/refresh` y recibe el access token (15 min).

Cuentas semilla (`V2`/`V3` de wellbeing): empleados `david.cajamarca@`, `mariana.torres@`,
`camilo.rincon@`, `sofia.mejia@nexura.co` y `andrea.gomez@`, `felipe.restrepo@`, `natalia.vargas@`,
`santiago.herrera@orbitalabs.co`; psicóloga `laura.martinez@zeal.co` (los demás psicólogos del directorio no tienen cuenta);
administradores `talento.humano@nexura.co`, `gestion.humana@orbitalabs.co`.

Desde scripts: `node tests/security/seg2-login.mjs` hace el flujo completo; para carga, `tests/k6/lib/zeal.js`
firma tokens con el secreto de **desarrollo** (no funciona con otro `JWT_SECRET`).

## 5. Rutas finales

Todas detrás de NGINX en `:8080`. Con token salvo las de `/api/auth/**`. Lo ajeno responde **404** (SEG-3).

| Método y ruta | Servicio | Rol |
|---|---|---|
| `POST /api/auth/microsoft` · `GET /api/auth/microsoft/callback` · `POST /api/auth/refresh` · `POST /api/auth/logout` | wellbeing | público (cookie) |
| `GET /api/wellbeing/psicologos` · `/{id}` · `/{id}/franjas?desde&hasta` | wellbeing | EMPLEADO |
| `GET /api/wellbeing/franjas/mias?desde&hasta` · `POST /api/wellbeing/franjas` · `DELETE /api/wellbeing/franjas/{id}` | wellbeing | PSICOLOGO |
| `POST /api/wellbeing/reservas` · `GET /api/wellbeing/reservas/mias` · `POST /api/wellbeing/reservas/{id}/cancelar` | wellbeing | EMPLEADO |
| `GET /api/wellbeing/reservas/agenda?desde&hasta` | wellbeing | PSICOLOGO |
| `GET /api/wellbeing/reservas/{id}/sala` · `GET …/sala/conexion` | wellbeing | participantes |
| `POST /api/wellbeing/reservas/{id}/sala/activar` | wellbeing | PSICOLOGO de la cita |
| `GET /api/wellbeing/cupos` · `POST /api/wellbeing/cupos/{offerId}/tomar` | wellbeing | EMPLEADO |
| `GET /api/chats/{conversationId}` · `GET|POST …/mensajes` | wellbeing | participantes |
| `GET /api/organizacion/empleados` | wellbeing | ADMIN |
| `GET /api/proyectos` · `/{id}` · `POST /api/proyectos/{id}/postulaciones` · `GET /api/postulaciones/mias` | marketplace | EMPLEADO |
| `GET /api/talleres` · `POST /api/talleres/{id}/inscripciones` · `GET /api/inscripciones/mias` | marketplace | EMPLEADO |
| `GET /api/talleres/{id}/sala` | marketplace | EMPLEADO inscrito / ADMIN de la empresa |
| `GET|POST /api/admin/proyectos` · `GET|POST /api/admin/talleres` | marketplace | ADMIN |
| `GET /api/notificaciones` · `POST /api/notificaciones/{id}/leida` · `POST /api/notificaciones/leidas` | realtime | autenticado |
| `GET /api/presencia/{userId}` | realtime | autenticado |
| `POST /api/telemetria` | realtime | autenticado |
| `/ws` (SockJS/STOMP; `Authorization` en el CONNECT) | realtime | autenticado |
| `/livekit/` (señalización de LiveKit) | livekit | token de sala |

STOMP (sin cambios de nombres): `/user/queue/{notificaciones,cupos-liberados,salas,chats,proyectos,talleres,postulaciones,inscripciones}`,
`/topic/franjas`, `/topic/presencia/{id}`, `/topic/organizaciones/{empresa}/{proyectos|talleres}`,
`/topic/{proyectos|talleres}/{id}/cupos`; envíos a `/app/chats/{id}/{mensajes|escribiendo}` y `/app/salas/{id}/senales`.

Contratos detallados para FE: `docs/contratos/` (auth, LiveKit 1:1, telemetría, 403→404).

## 6. Perfiles y archivos de Compose

| Archivo / perfil | Uso |
|---|---|
| Spring sin perfil | Desarrollo y contenedores (todo por variables de entorno, con valores de desarrollo) |
| Spring `test` | Pruebas (`src/test/resources/application-test.yml`: sin datos demo) |
| `docker-compose.yml` | Entorno local completo, 2 réplicas (`SERVICE_REPLICAS`) |
| `docker-compose.host-dev.yml` | Solo infraestructura; servicios en el host |
| `docker-compose.monitoring.yml` | Monitoreo local + consumidor de métricas de negocio |
| `docker-compose.prod.yml` + `.env.prod` | Un solo servidor (la VM de la demo) con Caddy TLS |
| `deploy/nodes/<nodo>/docker-compose.yml` | Despliegue multinodo (borde, web, servicios ×2, datos, medios, monitoreo) |

## 7. Variables de entorno por servicio

Comunes a los tres: `REDIS_HOST`, `REDIS_PORT`, `REDIS_PASSWORD` (vacía en local), `JWT_SECRET` (≥ 32
caracteres, **igual en los tres**), `JWT_ISSUER` (`zeal`), `APP_TIME_ZONE` (`America/Bogota`),
`CORS_ALLOWED_ORIGINS`, `SERVER_PORT`, `SHUTDOWN_TIMEOUT` (20s), `LOG_FORMAT` (`logstash`), `HOSTNAME` (réplica en logs).

**wellbeing**

| Variable | Defecto | Descripción |
|---|---|---|
| `DB_URL` | `jdbc:postgresql://localhost:5432/zeal_wellbeing_db` | Base |
| `DB_USERNAME` / `DB_PASSWORD` | `zeal_user` / dev | Usuario de la **aplicación** (sin DDL; R2-14) |
| `SPRING_FLYWAY_USER` / `SPRING_FLYWAY_PASSWORD` | = app | Usuario **propietario** que corre las migraciones |
| `DB_POOL_SIZE`, `DB_POOL_MIN_IDLE`, `DB_POOL_CONNECTION_TIMEOUT`, `PG_LOCK_TIMEOUT`, `TOMCAT_MAX_THREADS` | 20, 5, 10000, 5s, 200 | Ajuste (R2-27) |
| `JWT_TTL` | `15m` | Vida del access token |
| `OIDC_ISSUER_URI` | mock local | `https://login.microsoftonline.com/<tenant>/v2.0` |
| `OIDC_AUTHORIZATION_URI` | vacío | Solo si el navegador llega al proveedor por otra URL (mock en Docker) |
| `OIDC_CLIENT_ID` / `OIDC_CLIENT_SECRET` / `OIDC_REDIRECT_URI` | dev | App de Entra ID; redirect `https://<dominio>/api/auth/microsoft/callback` |
| `FRONTEND_URL` | `http://localhost:3000` | A dónde vuelve el navegador tras el login |
| `REFRESH_REMEMBER_TTL` / `REFRESH_SESSION_TTL` / `REFRESH_REUSE_GRACE` | 30d / 12h / 0s | Sesiones (R2-12) |
| `AUTH_COOKIE_SECURE` | true | `false` solo en http que no sea localhost |
| `ROOM_ICE_SERVERS` | STUN de Google | STUN |
| `TURN_URLS` / `TURN_SECRET` / `TURN_CREDENTIAL_TTL` | vacío / vacío / 2h | coturn con credenciales temporales (DT-5) |
| `LIVEKIT_PUBLIC_URL` / `LIVEKIT_API_KEY` / `LIVEKIT_API_SECRET` | `/livekit` / dev / dev | Sala 1:1 (DT-7) |
| `CACHE_TTL` | 60s | TTL de respaldo de la caché del directorio |
| `DEMO_DATA_ENABLED` | true | Datos de demostración |

**marketplace:** `DB_URL` (`…:5433/zeal_marketplace_db`), `DB_USERNAME`/`DB_PASSWORD`,
`SPRING_FLYWAY_USER`/`SPRING_FLYWAY_PASSWORD`, pool y bloqueos como wellbeing (en local `DB_POOL_SIZE=10`,
ver `REND.md`), `LIVEKIT_*`, `CACHE_TTL`, `DEMO_DATA_ENABLED`.

**realtime-gateway**

| Variable | Defecto | Descripción |
|---|---|---|
| `WELLBEING_BASE_URL` | `http://localhost:8081` | Para autorizar salas y chats |
| `RABBITMQ_HOST` / `RABBITMQ_STOMP_PORT` / `RABBITMQ_VHOST` | localhost / 61613 / `/` | Broker STOMP |
| `RABBITMQ_CLIENT_LOGIN` / `…_PASSCODE` · `RABBITMQ_SYSTEM_LOGIN` / `…_PASSCODE` | zeal / dev | Credenciales del relay |
| `PRESENCE_TTL` / `PRESENCE_SWEEP_INTERVAL` | 30s / 10s | Presencia en Redis (DT-2) |
| `EVENT_CLAIM_WINDOW` | 30s | Deduplicación de eventos entre réplicas |
| `STOMP_INBOUND_THREADS` / `STOMP_OUTBOUND_THREADS` | 8 / 8 | Hilos de los canales STOMP |
| `TELEMETRY_REQUESTS_PER_MINUTE` | 30 | Límite de telemetría por persona |

**business-metrics (8084):** `REDIS_HOST`, `REDIS_PORT`, `REDIS_PASSWORD`.

Infraestructura (`.env.example` en local, `.env.prod.example` en un servidor, `deploy/nodes/*/.env.example`
en multinodo): `POSTGRES_*`, `DB_APP_*`, `RABBITMQ_*`, `TURN_*`, `LIVEKIT_*`, `OIDC_*`, `GRAFANA_ADMIN_PASSWORD`.
**Nunca** valores reales en el repositorio: `.env` y `.env.prod` están en `.gitignore`.

## 8. Pruebas

```bash
# Cada servicio (unitarias + integración con Testcontainers + matriz de autorización + JaCoCo ≥ 80 %):
cd zeal-wellbeing-service && ./mvnw verify        # 102 pruebas
cd zeal-marketplace-service && ./mvnw verify      # 47
cd zeal-realtime-gateway && ./mvnw verify         # 46 (incluye dos réplicas reales)
cd zeal-infra-compose/services/zeal-business-metrics && ./mvnw verify

# Con el entorno arriba (zeal-infra-compose):
./tests/realtime/two-replicas.sh                  # DT-4: dos réplicas del gateway (20 verificaciones)
(cd tests/realtime && npm test)                   # RT-1/2/3 (usa la cita demo "en 5 min": recién sembrada, tras down -v)
node tests/security/seg2-login.mjs                # SEG-2: login con el proveedor de prueba
./tests/security/seg4-session-theft.sh            # SEG-4: robo de sesión en todas las réplicas
./tools/turn-check/turn-check.sh --from-wellbeing # DT-6: relé TURN forzado
./tests/disp/disp1.sh && ./tests/disp/disp2.sh    # DISP-1 / DISP-2
node tests/concurrency/c1-overbooking.mjs         # reto C-1 (y c2, c3)
cd tests/k6 && docker run --rm --network host -v "$PWD":/scripts grafana/k6:1.4.2 run /scripts/rend1-broadcast.js
```

Evidencias y resultados: `docs/evidencias/` (DT-4, HU-DT-02, DISP, SEG, MANT, REND, OBS).

## 9. Despliegue

- **Un servidor** (la VM actual): `docker compose -f docker-compose.prod.yml --env-file .env.prod up -d --build`
  (Caddy pide el certificado; coturn y RabbitMQ ya son parte del despliegue). Completar `.env.prod`
  desde `.env.prod.example` (nuevas: `RABBITMQ_*`, `TURN_*`, `TURN_DOMAIN`, `PUBLIC_IP`).
- **Varios nodos de Azure** (Sprint 2): `docs/cowork/RUNBOOK_DESPLIEGUE_MULTINODO.md` paso a paso
  (borde, web, servicios ×2, datos, medios, monitoreo), con `deploy/nodes/*`, `deploy/azure/provision.sh`
  y el pipeline `.github/workflows/deploy.yml` de cada servicio (GHCR + SSH, una réplica a la vez).
- Lo que se hace con el equipo reunido: `docs/cowork/CHECKLIST_COWORK.md`.

## 10. Problemas frecuentes

| Síntoma | Causa y solución |
|---|---|
| El gateway no queda *healthy* | Readiness incluye RabbitMQ (`stompBroker`): revisar `docker compose ps rabbitmq` y `RABBITMQ_*` |
| `ERROR … RESOURCE_LOCKED` en RabbitMQ | Algo publica en `/queue/...` en vez de `/amq/queue/...`: ver `BrokerDestinationInterceptor` |
| Login vuelve con `error=fallo` | `OIDC_*` mal configurado (emisor, audiencia, redirect) — el detalle está en `security_audit` y en el log `zeal.security.audit` |
| 401 en todas las APIs tras un robo/logout | Es la lista negra (SEG-4): volver a iniciar sesión |
| 404 donde antes había 403 | SEG-3 (`docs/contratos/cambios-403-404.md`) |
| Cambié `nginx/nginx.conf` y no se aplica | Está montado como archivo: `docker compose restart api-gateway` (un `sed -i` crea otro inodo) |
| `docker kill` y la réplica no vuelve | Es una parada manual; para simular una caída usar `crash()` de `tests/disp/lib.sh` |
| Logs ilegibles en la terminal | Son JSON (R2-29): `docker logs … | jq -r .message`, o `LOGGING_STRUCTURED_FORMAT_CONSOLE=` para texto |
