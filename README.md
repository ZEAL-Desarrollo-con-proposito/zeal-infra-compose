# zeal-infra-compose

Orquestación local de ZEAL: bases de datos por bounded context, broker de eventos, API Gateway y
pruebas de sustentación de los retos de concurrencia y tiempo real.

| Componente | Puerto | Rol |
|---|---|---|
| `api-gateway` (NGINX) | 8080 | Punto de entrada único del frontend (`VITE_API_BASE_URL=http://localhost:8080`) |
| `postgres-wellbeing` | 5432 | Wellbeing Domain (citas, chat: datos clínicos aislados) |
| `postgres-marketplace` | 5433 | Business Domain (convocatorias y talleres) |
| `redis-broker` | 6379 | Message Bus (Pub/Sub) y notificaciones |
| `zeal-wellbeing-service` | 8081 | corre en el host |
| `zeal-marketplace-service` | 8082 | corre en el host |
| `zeal-realtime-gateway` | 8083 | corre en el host (STOMP/SockJS en `/ws`) |

## Arranque

```bash
docker compose up -d && docker compose ps      # esperar "healthy"
(cd ../zeal-wellbeing-service   && ./mvnw spring-boot:run)
(cd ../zeal-marketplace-service && ./mvnw spring-boot:run)
(cd ../zeal-realtime-gateway    && ./mvnw spring-boot:run)
curl -s localhost:8080/gateway/health
```

## Enrutamiento del API Gateway

| Prefijo | Servicio |
|---|---|
| `/api/auth`, `/api/wellbeing`, `/api/chats` | wellbeing (8081) |
| `/api/proyectos`, `/api/postulaciones`, `/api/talleres`, `/api/inscripciones`, `/api/admin` | marketplace (8082) |
| `/api/notificaciones`, `/api/presencia`, `/ws` | realtime-gateway (8083) |

## Pruebas de sustentación

Con todo levantado (y `DEMO_DATA_ENABLED=true`, el valor por defecto):

```bash
node tests/concurrency/c1-overbooking.mjs      # 500 postulaciones → 10 ACEPTADA, 490 EN_ESPERA, occupied=10
node tests/concurrency/c2-double-booking.mjs   # 100 reservas a la misma franja → 1×201, 99×409
node tests/concurrency/c3-freed-slot-race.mjs  # 50 candidatos por un cupo liberado → 1×200, 49×409
(cd tests/realtime && npm install && npm test) # RT-1 (latencia del chat), RT-2 y RT-3, 22 verificaciones
```

Las pruebas de carga firman tokens con el secreto de **desarrollo** para simular cientos de
personas distintas; no funcionan (ni deben funcionar) contra un entorno con otro `JWT_SECRET`.
Cada ejecución crea su propia convocatoria/franjas, así que se pueden repetir.

## Datos

Los servicios usan esquemas propios (`wellbeing`, `marketplace`) gestionados con Flyway. Las tablas
del esquema `public` de versiones anteriores ya no se usan; si quieres empezar de cero:
`docker compose down -v` (borra los volúmenes).
