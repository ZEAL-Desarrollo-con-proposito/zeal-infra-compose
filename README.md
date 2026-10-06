# Zeal Wellbeing service

Spring Boot service for recurring psychologist availability and appointment reservations.

## Run locally

Start the infrastructure with `docker compose up -d`, then run `./mvnw spring-boot:run` (Windows: `mvnw.cmd spring-boot:run`). PostgreSQL and Redis connection settings can be overridden with `DB_URL`, `DB_USERNAME`, `DB_PASSWORD`, `REDIS_HOST`, and `REDIS_PORT`.

The service uses PostgreSQL for persistence. Hibernate schema updates are enabled by default for local development; set `DDL_AUTO=validate` when deploying with managed schema migrations.

## API

- `GET /api/psychologists/availability?from=YYYY-MM-DD&to=YYYY-MM-DD` — list psychologists and free occurrence slots for the inclusive date range.
- `POST /api/reservations` — reserve an available occurrence (`psychologistId`, `employeeId`, `startsAt` as ISO-8601 instant).

Reservations that conflict with an existing booking return `409 Conflict`. The recurring schedule is interpreted in each rule's time zone, so daylight-saving transitions are applied when occurrences are generated. Reservation changes are broadcast to connected STOMP clients at `/topic/availability`; clients connect to `/ws`. Redis Pub/Sub distributes those updates across service instances.
