# Evidencia DT-4 · Dos réplicas del Real-Time Gateway (HU-DT-01)

**Escenarios:** DISP-2, REND-1 · **Decisión:** ADR-04 (RabbitMQ como broker STOMP, presencia en Redis)
**Fecha de la ejecución local:** 2026-11-11 · **Entorno:** `docker-compose.yml` local, un host, 2 réplicas de cada servicio.

## Qué se cambió

| Pieza | Antes (MVP) | Ahora |
|---|---|---|
| Broker STOMP | Simple broker en memoria de una instancia | RabbitMQ 4.2 + `rabbitmq_stomp`, `enableStompBrokerRelay` (host, puerto, login/passcode y system login por variables `RABBITMQ_*`) |
| Tópicos | `/topic/organizaciones/{empresa}/proyectos` | **Mismos nombres para el cliente.** El gateway los traduce a la sintaxis de RabbitMQ (`/topic/organizaciones.{empresa}.proyectos`) y de vuelta. Ver "Ajustes de sintaxis" |
| Colas privadas | `/user/queue/...` resueltas en memoria | Mismos nombres. Cada réplica resuelve solo sus sesiones locales; las entregas privadas viajan entre réplicas por el canal Redis interno `zeal.gateway.user-deliveries` |
| Eventos de dominio (Redis) | Los procesaba la única instancia | Cada evento lo procesa **una** réplica: `SET NX` sobre su huella (`eventId` o SHA-256 del mensaje), ventana `EVENT_CLAIM_WINDOW` (30 s) |
| Presencia | `ConcurrentHashMap` | Redis: un sorted set por persona con una entrada por conexión y su vencimiento (TTL `PRESENCE_TTL`, 30 s), renovada con cada latido STOMP (10 s). Transiciones atómicas con Lua |
| Caché de accesos a salas/chats | `ConcurrentHashMap` | Redis con TTL (`zeal:rt:access:*`) |
| Balanceo de `/ws` | Un upstream fijo | NGINX: hash por id de sesión SockJS, réplicas descubiertas por DNS (`resolve`) |

## Ajustes de sintaxis de destinos de RabbitMQ

RabbitMQ STOMP solo admite `/topic/<routing key>` sin `/` (los niveles se separan con `.`, y `*`/`#`
son comodines), escapa `%` como `%25` en el `destination` de los MESSAGE, y declara las colas
`/queue/x` durables por defecto. Ajustes (en `zeal-realtime-gateway/.../broker/`):

1. **Tópicos:** `/topic/a/b/c` ↔ `/topic/a.b.c`. Dentro de un segmento, `.`, `*` y `#` se escapan como
   `%2E`, `%2A`, `%23`: el nombre de una empresa con puntos (`Nexura S.A.S.`) no rompe la clave y
   suscribirse a `/topic/presencia/*` **no** actúa como comodín (sería una fuga de presencia).
   El MESSAGE vuelve al navegador con el nombre original.
2. **Colas privadas:** el SUBSCRIBE a `/queue/x-user{sesión}` lleva `durable:false` y `auto-delete:true`
   (RabbitMQ la crea exclusiva de la conexión de esa sesión y la borra al cerrarse: 0 colas huérfanas).
3. **Publicación en colas privadas:** viaja como `/amq/queue/x-user{sesión}`, que entrega en una cola
   existente sin redeclararla. Un SEND a `/queue/...` sobre una cola exclusiva de otra conexión
   responde `RESOURCE_LOCKED` y RabbitMQ cierra la conexión compartida del relay (lo vimos en la
   primera prueba).
4. Nada de esto cambia el contrato: el frontend sigue usando exactamente los mismos destinos.

## DT-2 · Presencia: por qué barrido con bloqueo y no keyspace notifications

- Las keyspace notifications son Pub/Sub sin entrega garantizada: si en ese instante no hay réplica
  escuchando, el "offline" se pierde. Además exigen `notify-keyspace-events` en el servidor Redis y
  el evento `expired` se emite cuando Redis borra la clave, no cuando vence (puede retrasarse).
- El barrido (`PresenceTracker.sweepExpiredConnections`, cada `PRESENCE_SWEEP_INTERVAL` = 10 s, con
  ShedLock sobre Redis para que lo haga una réplica a la vez) es determinista: una conexión de una
  réplica caída se anuncia offline en ≤ TTL + intervalo (≤ 40 s).
- Varias pestañas/réplicas: la persona sigue en línea mientras quede una entrada vigente. Los scripts
  Lua deciden la transición de forma atómica, así que aunque dos réplicas actúen a la vez sobre la
  misma persona el cambio se anuncia una sola vez.

## DT-3 · Afinidad de `/ws`: por qué hash del id de sesión SockJS

- **`ip_hash` no sirve:** en una empresa todos los empleados salen por el mismo NAT corporativo, así
  que toda la empresa caería en la misma réplica (desbalance y punto único de falla por cliente).
- **Cookie de afinidad:** NGINX open source no tiene `sticky cookie` (es de NGINX Plus) y emularla con
  `map` + `Set-Cookie` falla si el navegador bloquea cookies de terceros o en la primera petición.
- **Elegido:** SockJS pone el id de su sesión en la ruta de cada petición
  (`/ws/{servidor}/{sesión}/{transporte}`). `hash $sockjs_session` envía todas las peticiones de una
  sesión (p. ej. `xhr` y `xhr_send` del transporte xhr-polling) a la misma réplica, sin cookies e
  independiente de la IP. `/ws/info` no tiene sesión y puede ir a cualquier réplica.
- **Sin `consistent`:** con `resolve` todas las réplicas comparten el nombre `realtime` y el hash
  consistente (que ubica sus puntos por nombre de servidor) degenera en round robin; se probó y las
  peticiones de una misma sesión se repartían 3/3 entre réplicas. Con `hash` simple quedan 6/6 en la
  misma réplica. Costo: al agregar una réplica cambian de réplica las sesiones de **respaldo**
  (polling/streaming) en curso, que se reconectan solas (`reconnectDelay` 5 s); las sesiones
  WebSocket ya establecidas no se mueven.
- Cabeceras `Upgrade`/`Connection`, `proxy_read_timeout`/`proxy_send_timeout` de 75 s (el latido es de
  10 s), `proxy_buffering off` y sin reintento en otra réplica (`proxy_next_upstream off`).

## Prueba 1 · Integración automatizada (Maven, CI)

`zeal-realtime-gateway/src/test/java/co/zeal/realtime/replicas/TwoReplicasIT.java` levanta **dos
contextos de Spring** (dos réplicas con su propio puerto) sobre Redis y RabbitMQ reales
(Testcontainers) y conecta cada cliente a una réplica distinta:

| Prueba | Verifica |
|---|---|
| `usersOnDifferentReplicasSeeEachOtherOnlineAndOffline` | online/offline entre réplicas + REST `/api/presencia` desde la otra réplica |
| `aUserStaysOnlineWhileATabRemainsOnAnyReplica` | cerrar una pestaña en A no la marca offline si sigue en B |
| `heartbeatsKeepAConnectionAliveBeyondItsTtl` | con TTL 3 s, el latido mantiene la conexión viva 7 s |
| `connectionsOfACrashedReplicaExpireAndAreAnnouncedOffline` | conexión de una réplica "muerta" → offline por barrido, una sola vez |
| `chatCrossesReplicasAndEchoesToTheSendersOtherTabs` | chat A → B, eco a la otra pestaña del remitente, sin duplicados |
| `spotsAndSlotsReachSubscribersOfBothReplicasExactlyOnce` | cupos y franjas llegan una vez a cada suscriptor de A y de B |
| `notificationIsStoredOnceAndReachesTheRecipientOnItsReplica` | la notificación se guarda una vez en Redis y llega a la réplica del destinatario |
| `adminsOfTheOrganizationOnAnyReplicaReceiveTheirPanelUpdate` | panel de admins en cualquier réplica; otra empresa no recibe nada |
| `webRtcSignalCrossesReplicas` | señal WebRTC de A a B |

```
name="co.zeal.realtime.websocket.RealtimeGatewayIT" time="11.835" tests="7" errors="0" skipped="0" failures="0"
name="co.zeal.realtime.replicas.TwoReplicasIT" time="35.06" tests="9" errors="0" skipped="0" failures="0"
```

Ejecutar: `cd zeal-realtime-gateway && ./mvnw verify` (requiere Docker).

## Prueba 2 · Docker Compose con NGINX (script)

`tests/realtime/two-replicas.sh` toma las IPs de las dos réplicas de `realtime` y conecta a David
**forzado a la réplica A** y a Laura **forzada a la réplica B** (directo a cada contenedor); la
administradora y Mariana entran por NGINX (`localhost:8080`), Mariana con el transporte de respaldo
`xhr-polling` para ejercitar la afinidad.

```bash
docker compose up -d --build && docker compose ps   # todo "healthy"
./tests/realtime/two-replicas.sh
```

Estado del entorno durante la ejecución:

```
zeal-api-gateway	Up 20 seconds (healthy)
zeal-infra-compose-marketplace-1	Up 7 minutes (healthy)
zeal-infra-compose-marketplace-2	Up 7 minutes (healthy)
zeal-infra-compose-realtime-1	Up 7 minutes (healthy)
zeal-infra-compose-realtime-2	Up 7 minutes (healthy)
zeal-infra-compose-wellbeing-1	Up 7 minutes (healthy)
zeal-infra-compose-wellbeing-2	Up 7 minutes (healthy)
zeal-livekit	Up 7 minutes
zeal-postgres-marketplace	Up 7 minutes (healthy)
zeal-postgres-wellbeing	Up 7 minutes (healthy)
zeal-rabbitmq	Up 7 minutes (healthy)
zeal-redis-broker	Up 7 minutes (healthy)
```

Salida:

```
Réplica A: http://172.19.0.11:8083 · Réplica B: http://172.19.0.12:8083 · Borde: http://localhost:8080

OK   David (réplica A) aparece en línea para Laura (réplica B) 
OK   GET /api/presencia por NGINX lo reporta online {"userId":"usr-empleado-001","status":"online"}
OK   chat de David (A) llega a Laura (B) (21 ms)
OK   eco del chat en la pestaña de David (A) 
OK   "escribiendo" de Laura (B) llega a David (A) 
OK   franja creada por NGINX (201)
OK   reserva por NGINX 201 (201)
OK   Laura (B) recibe /topic/franjas 
OK   David (A) recibe su notificación privada 
OK   convocatoria creada por NGINX (201)
OK   David (A) ve la convocatoria nueva de su empresa 
OK   la administradora recibe su panel 
OK   Mariana (xhr-polling por NGINX, con afinidad) recibe la convocatoria 
OK   postulación 201 (201)
OK   cupos en vivo en la réplica A 
OK   cupos en vivo en la réplica B 
OK   sin duplicados en tópicos (A) 
OK   sin duplicados en tópicos (B) 
OK   sin duplicados en colas privadas 
OK   David desconectado → Laura (B) lo ve offline 

20/20 verificaciones · RESULTADO: APROBADO
```

Colas en RabbitMQ después de la prueba (`rabbitmqctl list_queues name durable auto_delete`): ninguna
cola `*-user*` sobrevive a sus sesiones.

## Resultado

| Criterio de aceptación (HU-DT-01) | Estado |
|---|---|
| RabbitMQ con STOMP como broker relay en lugar del broker en memoria | ✅ |
| Presencia en Redis con expiración por latido, compartida por las réplicas | ✅ |
| Dos usuarios en réplicas distintas se ven en línea y reciben mensajes y avisos | ✅ (9 pruebas IT + 20/20 en Compose) |
| Afinidad para los transportes de respaldo de SockJS | ✅ (xhr-polling por NGINX) |
