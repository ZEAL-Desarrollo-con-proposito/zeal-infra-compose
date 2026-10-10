# Servicio Zeal Wellbeing

Servicio Spring Boot para gestionar la disponibilidad recurrente de psicólogos y la reserva de citas.

## Ejecución local

Inicia la infraestructura con `docker compose up -d` y luego ejecuta `./mvnw spring-boot:run` (en Windows: `mvnw.cmd spring-boot:run`). La configuración de conexión a PostgreSQL y Redis puede sobrescribirse mediante las variables `DB_URL`, `DB_USERNAME`, `DB_PASSWORD`, `REDIS_HOST` y `REDIS_PORT`.

El servicio utiliza PostgreSQL para la persistencia. Las actualizaciones automáticas del esquema mediante Hibernate están habilitadas por defecto para el desarrollo local; establece `DDL_AUTO=validate` al desplegar la aplicación utilizando migraciones de esquema gestionadas.

## API

- `GET /api/psychologists/availability?from=YYYY-MM-DD&to=YYYY-MM-DD` — lista los psicólogos y los espacios disponibles (sesiones) para el rango de fechas indicado (inclusive).
- `POST /api/reservations` — reserva una sesión disponible (`psychologistId`, `employeeId`, `startsAt` en formato ISO-8601).
- `DELETE /api/reservations/{reservationId}` — cancela una reserva enviando el `employeeId` propietario en el cuerpo JSON. Devuelve `204 No Content`; una reserva inexistente o que no pertenezca al empleado devuelve `404`, y una cancelación repetida devuelve `409`.

Las reservas que entren en conflicto con una cita ya existente devolverán un código `409 Conflict`. Las cancelaciones conservan el registro y cambian su estado; la franja queda disponible nuevamente y puede reservarse otra vez. Para bases de datos existentes, aplica `src/main/resources/db/migration/V1__reservation_cancellation.sql` antes de desplegar con `DDL_AUTO=validate`: conserva las citas previas como activas y reemplaza la restricción única global por una restricción solo para reservas activas.

El horario recurrente se interpreta según la zona horaria de cada regla, por lo que se aplican los cambios de horario de verano/invierno al generar las sesiones. Los cambios en las reservas se difunden a los clientes STOMP conectados a través del canal `/topic/availability`; el evento lleva `available: false` cuando se reserva una franja y `available: true` cuando se libera. Los clientes deben conectarse a `/ws`. Redis Pub/Sub distribuye dichas actualizaciones entre las distintas instancias del servicio.

## Adaptador HTTP local de desarrollo

El perfil opcional `local-api` expone un proxy temporal en `http://localhost:8080`: `/api/chats/**` y `/api/marketplace/**` se envían a Marketplace (`8082`) y las demás rutas `/api/**` a Wellbeing (`8081`). Los destinos se pueden cambiar con `LOCAL_MARKETPLACE_UPSTREAM` y `LOCAL_WELLBEING_UPSTREAM`; este proxy no se inicia con el `docker compose up` habitual y se puede sustituir por el API Gateway definitivo.

En la raíz del frontend, el archivo local ignorado por Git `.env.development.local` selecciona `VITE_API_MOCKING=disabled` y `VITE_API_BASE_URL=http://localhost:8080`. Para levantar el proxy, desde esta carpeta ejecuta `docker compose --profile local-api up -d local-api-gateway`; inicia también Marketplace en `8082`, Wellbeing en `8081` y el Real-Time Gateway en `8083`. Reinicia Vite después de cambiar las variables de entorno. Al integrar el API Gateway definitivo, elimina o ajusta `.env.development.local` y cambia los upstreams o retira el perfil local.