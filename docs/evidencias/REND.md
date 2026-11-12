# Evidencia REND · Rendimiento y latencia en tiempo real (HU-BE-24, R2-24..R2-28)

> **Ensayo local reducido** (2026-11-11): todo en un solo equipo de 12 núcleos — 2 réplicas de cada
> servicio, PostgreSQL, Redis, RabbitMQ, NGINX **y el generador de carga k6** compitiendo por la misma CPU.
> La **ejecución oficial** es sobre el despliegue distribuido, con k6 en una máquina distinta a los
> servicios (R2-28, ver `docs/cowork/CHECKLIST_COWORK.md`).

## Escenarios

- **REND-1:** 500 empleados conectados repartidos entre réplicas; una publicación llega a todos con p95 ≤ 500 ms, 0 eventos perdidos y 0 errores.
- **REND-2:** 500 postulaciones simultáneas a una convocatoria de 10 cupos → 100 % con respuesta definitiva, p95 ≤ 1 s, exactamente 10 aceptadas, 0 sobreasignaciones.

## Resultados del ensayo local

| Escenario | Medida | Resultado | Objetivo | Estado |
|---|---|---|---|---|
| REND-1 | clientes conectados por WebSocket/STOMP | 500/500 (255 + 245 por réplica) | 500 | ✅ |
| REND-1 | entregas (3 publicaciones × 500) | 1500, **0 perdidas** | 0 perdidas | ✅ |
| REND-1 | latencia POST de la administradora → mensaje en el cliente | p50 54 ms · **p95 74 ms** · p99 76 ms | p95 ≤ 500 ms | ✅ |
| REND-2 | respuestas definitivas (ACEPTADA / EN_ESPERA) | **500/500**, 0 errores | 100 % | ✅ |
| REND-2 | aceptadas / `occupied` en la base | **10 / 10** | exactamente 10 | ✅ |
| REND-2 | latencia de la postulación | p50 1,01 s · **p95 1,33 s** · p99 1,35 s | p95 ≤ 1 s | ⚠️ local, ver abajo |
| Estrés (reducido) | 100 → 700 req/s en 4 escalones de 20 s | p95 9,6 ms, 0 % errores, sin quiebre | — | punto de quiebre: ejecución oficial |

### REND-2: qué se cambió y cómo evolucionó

| Versión | p95 | Errores | Hallazgo |
|---|---|---|---|
| MVP (`SELECT … FOR UPDATE` + conteo de la lista de espera dentro del bloqueo) | 4,43 s | 68 × 500 | el pool se agotaba esperando el bloqueo; `COUNT(*)` crecía con cada postulación |
| Contador `waitlisted` en la fila (O(1)) + chequeo de duplicado fuera del bloqueo | 3,50 s | 0 | correcto, pero ~7 ms por postulación con la fila bloqueada |
| Reclamo atómico en una transacción corta (`SpotClaims`), inserción fuera del bloqueo | 2,45 s → 1,52 s (JIT caliente) | 0 | ~1 ms por postulación en la fila |
| + una sola sentencia (CTE `FOR UPDATE` + `UPDATE`) y pool de 10 conexiones | **1,33 s** | 0 | más conexiones empeora: la cola de bloqueos de PostgreSQL crece (con 40: > 1 min y `lock_timeout`) |

Límite físico medido en este equipo con `pgbench` sobre una sola fila caliente: ~1 250 commits/s (0,75 ms
por commit). Las 500 postulaciones se serializan en esa fila por diseño (es lo que garantiza 0
sobreasignaciones), así que el piso es ~0,4-0,6 s más el resto de la petición, que aquí compite por CPU
con k6 y las demás réplicas. En el despliegue distribuido (base en su propio nodo, generador aparte)
se espera bajar del segundo; si no, la siguiente táctica es agrupar los reclamos de una misma
convocatoria (un `UPDATE` por lote) — anotado como riesgo en el reporte final.

## R2-27 · Por qué la asignación de cupos no puede sobreasignar

`SpotClaims.claim` es **una sola sentencia** en una transacción propia:

```sql
WITH current AS (
    SELECT id, occupied < capacity AS free FROM projects
    WHERE id = ? AND organization = ? AND closes_at > ?
    FOR UPDATE                      -- bloquea la fila; espera al que la tenga
)
UPDATE projects p SET occupied   = p.occupied   + CASE WHEN current.free THEN 1 ELSE 0 END,
                      version    = p.version    + CASE WHEN current.free THEN 1 ELSE 0 END,
                      waitlisted = p.waitlisted + CASE WHEN current.free THEN 0 ELSE 1 END
FROM current WHERE p.id = current.id
RETURNING current.free, p.capacity, p.occupied, p.version, p.waitlisted
```

1. `FOR UPDATE` serializa a todas las réplicas sobre la fila de la convocatoria; `free` se evalúa **después**
   de obtener el bloqueo, con el valor ya confirmado por la transacción anterior (READ COMMITTED vuelve
   a leer la fila bloqueada).
2. La misma sentencia suma el cupo o el puesto de espera: no hay ventana entre "leer" y "escribir".
3. El CHECK `ck_projects_no_overbooking (occupied <= capacity)` es la última red: aunque hubiera un error
   de código, la base rechaza la sobreasignación.
4. La postulación se inserta después; si dos pestañas de la misma persona llegan a la vez, la restricción
   única (proyecto, persona) rechaza la segunda y se **compensa** devolviendo el cupo
   (`OverbookingConcurrencyIT.simultaneousDuplicateSubmissionsTakeASingleSpot`).
5. `lock_timeout` (`PG_LOCK_TIMEOUT`, 5 s) evita esperas infinitas: si vence, 409 "intenta de nuevo"
   (nunca 500 ni asignación a medias).

Pruebas: `OverbookingConcurrencyIT` (500 hilos → exactamente 10 ACEPTADA, puestos 1..490 sin repetir,
`version` = 10) y REND-2 por NGINX con dos réplicas.

Talleres y franjas usan el mismo principio con `SELECT … FOR UPDATE` sobre su fila (su concurrencia
real es mucho menor).

## R2-27 · Parámetros por variables de entorno

| Variable | Defecto | Servicio | Uso |
|---|---|---|---|
| `DB_POOL_SIZE` | 20 (marketplace local: 10) | wellbeing, marketplace | HikariCP `maximum-pool-size` |
| `DB_POOL_MIN_IDLE` | 5 | wellbeing, marketplace | conexiones ociosas |
| `DB_POOL_CONNECTION_TIMEOUT` | 10000 ms | wellbeing, marketplace | espera máxima por una conexión |
| `PG_LOCK_TIMEOUT` | 5s | wellbeing, marketplace | `SET lock_timeout` de cada conexión |
| `TOMCAT_MAX_THREADS` | 200 | wellbeing, marketplace | hilos HTTP |
| `STOMP_INBOUND_THREADS` / `STOMP_OUTBOUND_THREADS` | 8 / 8 | realtime-gateway | canales STOMP de entrada y salida |
| `CACHE_TTL` | 60s | wellbeing, marketplace | TTL de respaldo de la caché Redis |

## R2-24 · commitTimestamp y latencia de entrega

- Todos los eventos de Redis llevan ahora `eventId`, `commitTimestamp` (hora del commit de la transacción;
  se publican con `@TransactionalEventListener(AFTER_COMMIT)`) y `correlationId`. Son campos **nuevos**:
  los consumidores existentes los ignoran (retrocompatible) y el gateway usa `eventId` para deduplicar.
- Métrica `zeal_realtime_delivery_latency_seconds` (timer con histograma, etiqueta `source` = canal o
  `chat`): commit → envío por STOMP. En chat se mide desde `sentAt` del mensaje guardado.
  Pruebas: `DeliveryLatencyTest`.

## R2-26 · Caché en Redis

| Caché | Clave | Invalidación (eventos de dominio existentes) | Prueba |
|---|---|---|---|
| Directorio de psicólogos (wellbeing) | `zeal:cache:psychologist-directory::todos` | `zeal.wellbeing.slots` | `DirectoryCacheIT` |
| Catálogo de talleres por empresa (marketplace) | `zeal:cache:workshop-catalog::<empresa>` | `zeal.marketplace.workshops.published`, `…workshops.spots` | `WorkshopCatalogCacheIT` |

Valores serializados con su tipo concreto (sin información de clases en el JSON) y TTL de respaldo
`CACHE_TTL`. Cada réplica escucha los eventos y limpia la caché compartida (idempotente).

## R2-25 · Scripts k6

| Script | Escenario |
|---|---|
| `tests/k6/rend1-broadcast.js` | REND-1: `CLIENTS` (500) conexiones WebSocket/STOMP reales por NGINX (`/ws/websocket`, latido 10 s); una administradora publica `PUBLICATIONS` (3) convocatorias; cada cliente mide su latencia. Umbrales: p95 < 500 ms, 0 perdidos, 100 % conectados |
| `tests/k6/rend2-applications.js` | REND-2: 500 postulaciones simultáneas a 10 cupos. Umbrales: p95 < 1 s, 0 fallas, exactamente 10 aceptadas, 0 sin decisión; teardown verifica `occupied = 10` |
| `tests/k6/rend-stress.js` | R2-28: escalones de tasa hasta romper (aborta al pasar p95 1 s o 1 % de errores) |
| `tests/k6/disp-load.js` | carga habitual de DISP-1/DISP-2 |

**Autenticación de carga:** k6 firma access tokens de ZEAL con el `JWT_SECRET` del entorno de pruebas
(`tests/k6/lib/zeal.js`); funciona solo donde ese secreto es el de desarrollo/pruebas, nunca en producción.

```bash
cd tests/k6
docker run --rm --network host -v "$PWD":/scripts grafana/k6:1.4.2 run /scripts/rend1-broadcast.js
docker run --rm --network host -v "$PWD":/scripts grafana/k6:1.4.2 run /scripts/rend2-applications.js
docker run --rm --network host -e START=50 -e STEP=50 -e STEPS=10 -v "$PWD":/scripts grafana/k6:1.4.2 run /scripts/rend-stress.js
```

## Plantilla de la ejecución oficial (cowork)

| Medida | Resultado | Objetivo |
|---|---|---|
| Fecha / responsable / máquina generadora (≠ nodos de servicios) | | |
| REND-1 p50 / p95 / p99 | | p95 ≤ 500 ms |
| REND-1 entregas / perdidas / errores | | 1500 / 0 / 0 |
| REND-2 p50 / p95 / p99 | | p95 ≤ 1 s |
| REND-2 aceptadas / sin decisión / `occupied` | | 10 / 0 / 10 |
| Estrés: último escalón sano (req/s, p95) | | — |
| Estrés: escalón de quiebre y causa (CPU, pool, base, gateway…) | | — |
