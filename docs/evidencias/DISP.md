# Evidencia DISP · Disponibilidad y escalabilidad horizontal (HU-BE-19, R2-1..R2-3, R2-7)

> **Ensayo local** (un host, `docker-compose.yml`, 2 réplicas por servicio). La **ejecución oficial**
> es sobre el despliegue distribuido en la sesión cowork, con el generador de carga en otra máquina
> (ver `docs/cowork/CHECKLIST_COWORK.md`). Fecha del ensayo: 2026-11-11.

## Escenarios

- **DISP-1 — Falla de una instancia:** con carga habitual una instancia deja de responder → otra atiende la
  solicitud, 0 errores visibles, la instancia vuelve en < 1 min sin intervención manual, 0 operaciones
  confirmadas perdidas.
- **DISP-2 — La demanda se duplica:** se agrega una instancia del servicio más exigido → recibe tráfico en
  < 2 min sin cambios de código ni reinicio de las demás; p95 ≤ 500 ms.

## Tácticas y dónde están

| Táctica | Implementación |
|---|---|
| Ping/Echo, Heartbeat | Health checks de Docker sobre `/actuator/health/readiness`; latido STOMP de 10 s; NGINX `max_fails=3 fail_timeout=10s` (chequeo pasivo) |
| Active Redundancy | 2 réplicas activas por servicio detrás de NGINX `least_conn` |
| Retry | `proxy_next_upstream error timeout http_502 http_503 http_504` **solo** para métodos idempotentes (sin `non_idempotent`); un POST solo se reintenta si no llegó a enviarse (conexión rechazada) |
| Escalating Restart | `restart: unless-stopped`: Docker reinicia la réplica cuyo proceso muere |
| Maintain Multiple Copies of Computations | Ninguna réplica guarda estado en memoria (R2-1, HU-DT-01): sesiones, presencia, cachés y bloqueos viven en PostgreSQL/Redis/RabbitMQ |
| Increase Resources | `docker compose up --scale <servicio>=N`; NGINX descubre las réplicas por DNS (`resolve`, cada 5 s) |

## R2-1 · Servicios sin estado

- Revisión de `wellbeing` y `marketplace`: no hay `@Scheduled`, cachés locales, `HttpSession`, mapas
  estáticos ni `ConcurrentHashMap` (la API es stateless con JWT). El gateway quedó sin estado en HU-DT-01.
- **Siembra de datos de demostración** (`ApplicationRunner` "si no hay datos, siembra"): con dos réplicas
  arrancando a la vez ambas sembraban. Ahora toman un advisory lock de PostgreSQL ligado a la transacción
  (`ClusterLock`): la segunda espera y encuentra los datos. Prueba: `ClusterLockIT`.
- **Flyway una sola vez:** se usa el bloqueo propio de Flyway. En PostgreSQL, `migrate` toma un advisory
  lock (`pg_advisory_lock`) durante toda la migración: si dos réplicas arrancan juntas, la segunda espera
  y al entrar ve `flyway_schema_history` al día y no ejecuta nada. Se descartó un job de migración
  separado porque agrega una pieza de despliegue más sin ganar seguridad (cada versión sigue aplicándose
  una sola vez y en orden). Con R2-14 la migración corre con el usuario propietario y la app con uno sin
  privilegios de DDL.
- **ShedLock sobre PostgreSQL:** tabla `shedlock` por migración en cada base (`wellbeing.shedlock` V4,
  `marketplace.shedlock` V2), `@EnableSchedulerLock` con hora de la base. Toda tarea `@Scheduled` debe
  llevar `@SchedulerLock`. Prueba: `ClusterLockIT.scheduledTaskLockIsExclusiveAcrossReplicas`.

## R2-3 · Readiness y liveness

| Servicio | `/actuator/health/readiness` | `/actuator/health/liveness` |
|---|---|---|
| wellbeing | `readinessState, db, redis` | `livenessState` |
| marketplace | `readinessState, db, redis` | `livenessState` |
| realtime-gateway | `readinessState, redis, stompBroker` (conexión de sistema del relay con RabbitMQ) | `livenessState` |

`server.shutdown=graceful` + `spring.lifecycle.timeout-per-shutdown-phase=20s`; `stop_grace_period: 30s` en Compose.

Verificación (RabbitMQ detenido unos segundos):

```
RabbitMQ caído → readiness: HTTP/1.1 503  · liveness: HTTP/1.1 200
RabbitMQ de vuelta → readiness: HTTP/1.1 200  (tras ~6 s)
```

> Nota: `docker kill`/`docker stop` cuentan como parada **manual** y Docker no aplica la política de
> reinicio. Los scripts simulan la caída real matando el proceso desde el espacio de PIDs del host
> (`crash()` en `tests/disp/lib.sh`), que es lo que ocurre ante un crash de la JVM.

## DISP-1 · `tests/disp/disp1.sh`

Carga constante de 40 req/s durante 120 s (k6, `tests/k6/disp-load.js`: 30 % directorio de psicólogos,
30 % catálogo de talleres, 20 % notificaciones, 20 % postulaciones con confirmación 201). A los 30 s se
cae una réplica de **cada** servicio a la vez.

```
== DISP-1 · 40 req/s durante 120s; caída de una réplica de cada servicio a los 30s
   19:12:49 cae zeal-infra-compose-wellbeing-1
   19:12:50 cae zeal-infra-compose-marketplace-1
   19:12:50 cae zeal-infra-compose-realtime-1

| Medida | Resultado | Objetivo |
|---|---|---|
| Peticiones | 4802 | — |
| Errores visibles | 0 (0.000 %) | 0 |
| Réplica de wellbeing de vuelta (healthy) | 16 s | < 60 s |
| Réplica de marketplace de vuelta (healthy) | 17 s | < 60 s |
| Réplica de realtime de vuelta (healthy) | 11 s | < 60 s |
| Postulaciones confirmadas (201) | 990 | — |
| Postulaciones en la base | 990 | = confirmadas |
| Operaciones confirmadas perdidas | 0 | 0 |
| p95 | 16 ms | — |
RESULTADO: APROBADO
```

"Operaciones confirmadas perdidas" = postulaciones que el servidor respondió con 201 y que no están en
`marketplace.applications` al final de la prueba.

## DISP-2 · `tests/disp/disp2.sh`

40 req/s; a los 30 s se agrega otro escenario igual (carga ×2) y en el mismo instante
`docker compose up --scale marketplace=3`. NGINX no se recarga ni se reinicia nada.

```
== DISP-2 · 40 req/s; a los 30s se duplica y marketplace pasa de 2 a 3 réplicas
   19:10:18 carga x2 y docker compose up --scale marketplace=3
   réplica nueva zeal-infra-compose-marketplace-3 (172.19.0.14)

| Medida | Resultado | Objetivo |
|---|---|---|
| Peticiones (carga habitual + duplicada) | 8402 | — |
| Réplica nueva atiende su primera petición tras el escalado | 13 s | < 120 s |
| Peticiones atendidas por la réplica nueva | 1007 | > 0 |
| p95 de toda la prueba | 15 ms | ≤ 500 ms |
| Tasa de error | 0.000 % | — |
| Reinicios de las demás réplicas o de NGINX | 0 (solo se creó la nueva) | 0 |
RESULTADO: APROBADO
```

El tiempo hasta la primera respuesta es el arranque de la JVM más las migraciones. El DNS de Docker
publica la réplica al crearla, antes de que esté lista: NGINX la prueba, recibe *connection refused* y
reintenta en otra (0 errores visibles). En multinodo, la réplica nueva se agrega como registro A del DNS
privado (ver `nginx/nginx.multinode.conf.template`).

## Cómo repetirlo

```bash
docker compose up -d --build            # 2 réplicas por servicio, todo healthy
./tests/disp/disp1.sh                   # RATE, DURATION, CRASH_AFTER configurables
./tests/disp/disp2.sh                   # SERVICE, RATE, DOUBLE_AT configurables
```

## Plantilla para la ejecución oficial (cowork)

| Medida | DISP-1 | DISP-2 | Objetivo |
|---|---|---|---|
| Fecha / responsable | | | |
| Generador de carga (máquina, IP) | | | distinta a los nodos de servicios |
| Carga (req/s, duración) | | | |
| Errores visibles | | — | 0 |
| Recuperación de la réplica caída | | — | < 60 s |
| Operaciones confirmadas perdidas | | — | 0 |
| Tiempo hasta que la réplica nueva atiende | — | | < 120 s |
| p95 | | | ≤ 500 ms |
