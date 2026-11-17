# Evidencia REND · Rendimiento y latencia en tiempo real (HU-BE-24, R2-24..R2-28)

> **Ensayo local reducido** (2026-11-11): todo en un solo equipo de 12 núcleos — 2 réplicas de cada
> servicio, PostgreSQL, Redis, RabbitMQ, NGINX **y el generador de carga k6** compitiendo por la misma CPU.
> La **ejecución oficial** es sobre el despliegue distribuido, con k6 en una máquina distinta a los
> servicios (R2-28, ver `docs/cowork/CHECKLIST_COWORK.md`).

## Resumen para la sustentación

| Escenario | Naturaleza | Resultado en el despliegue real de Azure | Estado |
|---|---|---|---|
| **REND-1** | **Escenario oficial** | 500/500 conectados, **p95 132 ms** (meta ≤ 500 ms), 0 eventos perdidos | ✅ **Cumple** |
| REND-2 | Adicional (no oficial) | 10 aceptadas exactas, 0 errores, 0 sobreasignaciones; p95 del servidor ≈ 0,6–1,0 s y del cliente 1,1–2,4 s (meta ≤ 1 s) | ⚠️ **Cumple parcialmente** |

REND-2 cumple lo funcional (exactamente 10 aceptadas, 500/500 respuestas, 0 sobreasignaciones) y la latencia queda en el
borde de la meta. La causa es de capacidad: la cuenta de estudiante limita a 6 vCPU por región, así que la VM A tiene 2 vCPU
(B tiene 4) y el generador de carga comparte A; con 500 peticiones simultáneas sobre 3 JVM la CPU media de las máquinas
fue del 40–62 %. El análisis completo está en la sección "REND-2 en el despliegue REAL de Azure" más abajo.

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
| REND-2 | latencia de la postulación | p50 0,82–0,97 s · **p95 1,2–1,5 s** (con el JIT caliente) · p99 1,3–1,5 s | p95 ≤ 1 s | ⚠️ local, ver abajo |
| Estrés (reducido) | 100 → 700 req/s en 4 escalones de 20 s | p95 9,6 ms, 0 % errores, sin quiebre | — | punto de quiebre: ejecución oficial |

### REND-2: qué se cambió y cómo evolucionó

| Versión | p95 | Errores | Hallazgo |
|---|---|---|---|
| MVP (`SELECT … FOR UPDATE` + conteo de la lista de espera dentro del bloqueo) | 4,43 s | 68 × 500 | el pool se agotaba esperando el bloqueo; `COUNT(*)` crecía con cada postulación |
| Contador `waitlisted` en la fila (O(1)) + chequeo de duplicado fuera del bloqueo | 3,50 s | 0 | correcto, pero ~7 ms por postulación con la fila bloqueada |
| Reclamo atómico en una transacción corta (`SpotClaims`), inserción fuera del bloqueo | 2,45 s → 1,52 s (JIT caliente) | 0 | ~1 ms por postulación en la fila |
| + una sola sentencia (CTE `FOR UPDATE` + `UPDATE`) y pool de 10 conexiones | **1,33 s** | 0 | más conexiones empeora: la cola de bloqueos de PostgreSQL crece (con 40: > 1 min y `lock_timeout`) |

| + reclamos agrupados por convocatoria (un `UPDATE` por lote, hasta 100; media medida 14 por lote) | **1,2–1,5 s** (tras calentar; 1.ª ejecución 2,4 s) | 0 | el reclamo medio bajó de ~0,43 s a ~0,12–0,18 s; el cuello pasó a guardar la postulación (pool de 10 por réplica) y a la CPU compartida |
| + pool de 20 conexiones por réplica (descartado) | 1,2–1,5 s | 0 | sin mejora: se vuelve a 10 |

Con los reclamos agrupados `SpotClaims` ya no es el cuello: cada petición espera su lote sin tomar conexión y
solo usa una para insertar su postulación. Se respeta el orden de llegada (las primeras reciben los cupos, las
siguientes puestos correlativos de la lista de espera) y la seguridad no cambió: el lote es una sola sentencia con
`FOR UPDATE` y `LEAST(pedidos, libres)`, y el CHECK `occupied <= capacity` sigue como última red
(`OverbookingConcurrencyIT`: 500 hilos → exactamente 10 aceptadas, puestos 1..490, `version` = 10).

**Resultado honesto:** en este equipo (12 hilos compartidos por k6, 2 réplicas Java, PostgreSQL y Redis) el p95 sigue
entre 1,2 y 1,5 s, es decir **no se alcanzó 1 s localmente**, aunque no hay errores ni sobreasignación. Lo que queda
es CPU de una sola máquina atendiendo ~400 peticiones HTTP/s de 500 conexiones a la vez; no se usó
`synchronous_commit=off` porque arriesgaría perder operaciones confirmadas. La medición válida es la del despliegue
distribuido (base de datos en su propio nodo, generador de carga aparte); métricas para diagnosticar allí:
`zeal_marketplace_spot_claim_seconds`, `zeal_marketplace_spot_claim_batch_size`,
`zeal_marketplace_application_save_seconds` y `hikaricp_connections_pending`.

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


## REND-2 en el despliegue REAL de Azure (2026-11-15)

`tests/k6/rend2-applications.js` desde un equipo externo (Colombia) contra el despliegue (A: 2 vCPU, B: 4 vCPU).

| Medida | Corrida 1 | Corrida 3 | Objetivo |
|---|---|---|---|
| Respuestas definitivas | 500/500, 0 errores | 500/500, 0 errores | 100 % |
| Aceptadas / `occupied` | 10 / 10 | 10 / 10 | exactamente 10 |
| p95 | **5,36 s** | **3,03 s** (avg 1,75 s) | ≤ 1 s ✗ |

Correcto pero **no cumple la latencia**: el equipo de carga está a ≈ 100 ms de Azure y abre 500 conexiones TLS a la vez,
y la máquina A tiene solo 2 vCPU. Para aislar esa parte hay que repetirlo desde una VM dentro de Azure y con más
vCPU (la cuota de la cuenta de estudiante es de 6 vCPU por región). Una corrida intermedia (corrida 2) no envió
peticiones por un fallo de arranque del script y se descartó.


## REND-1 en el despliegue REAL de Azure (2026-11-15)

500 conexiones WebSocket/STOMP reales y 3 publicaciones, con k6 ejecutado **desde la VM A** contra el balanceador de B por la
red privada (`http://10.20.0.4:8080`), para no medir la red de Internet ni el TLS del equipo de carga. Los WebSockets
se reparten por sesión entre los gateways de B y de A.

| Medida | Resultado | Objetivo |
|---|---|---|
| Conexiones establecidas | **500 / 500** (101) | 100 % |
| Latencia publicación → cliente | p50 94 ms · **p95 132 ms** · p99 137 ms | p95 ≤ 500 ms |
| Entregados / perdidos | 1500 / **0** | 0 perdidos |

Un primer intento desde un equipo doméstico (Internet) conectó solo 244 de 500 WebSockets: las otras 256 nunca llegaron
a las VMs (ninguna de las dos máquinas las registró), es decir, el límite estaba en la red del equipo de carga y no en
el servicio; ese intento se descartó como medición.

## REND-2 en el despliegue REAL de Azure: medida desde el cliente y desde el servidor (2026-11-15)

k6 desde la VM A contra el balanceador de B (red privada). El p95 del servidor sale de Prometheus
(`http_server_requests_seconds` de `POST /api/proyectos/{id}/postulaciones`, el mismo dato que ve Grafana en el tablero técnico).

| Corrida | p95 cliente (k6) | p95 servidor | p50 servidor | Respuestas / aceptadas |
|---|---|---|---|---|
| 1 | 2,36 s | (sin muestras: scrape pendiente) | — | 500/500 · 10 |
| 2 | 1,06 s | 0,62 s | 0,27 s | 500/500 · 10 |
| 3 | 1,62 s | 1,05 s | 0,34 s | 500/500 · 10 |

Siempre exactamente 10 aceptadas, `occupied = 10` y 0 errores. Dentro del servicio, el p95 del reclamo de cupo es
0,24–0,25 s y el del guardado 0,27–0,29 s: el reclamo agrupado (`SpotClaims`) ya no es el cuello. **El p95 sigue entre
≈ 0,6 y ≈ 1,0 s en el servidor y entre 1,1 y 2,4 s medido por el cliente**, es decir, la meta de ≤ 1 s es borderline del lado del
servidor y no se cumple del lado del cliente. Análisis: A tiene 2 vCPU y B 4 vCPU (cuota de la cuenta de estudiante), el
generador de carga comparte A y la CPU media de las máquinas durante la corrida fue del 40–62 %; hay 500 peticiones
simultáneas sobre 3 JVM. La medición por `increase()` con pocas muestras de scrape es ruidosa (±0,2 s); para una cifra
estable harían falta una VM de carga aparte y más vCPU. Desde un equipo doméstico por Internet el p95 fue de 3,0–5,4 s
(red y 500 handshakes TLS), sección anterior.
