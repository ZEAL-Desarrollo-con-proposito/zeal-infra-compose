# Evidencia OBS · Observabilidad (HU-BE-25, R2-29..R2-33) y MANT-2 (R2-31)

**OBS-1:** si un componente supera p95 > 1 s o > 1 % de errores durante 2 min → alerta en ≤ 3 min que
indica el componente; tablero que lo identifica en ≤ 5 min con estado, métricas y registros; 0 datos
personales o de chat en los logs. Ensayo local 2026-11-11 con `docker-compose.yml` +
`docker-compose.monitoring.yml` (2 réplicas por servicio).

## Cómo levantarlo

```bash
docker compose -f docker-compose.yml -f docker-compose.monitoring.yml up -d --build
# Grafana http://localhost:3001 (admin / GRAFANA_ADMIN_PASSWORD, por defecto zeal-dev-grafana)
# Prometheus http://localhost:9090 · Alertmanager http://localhost:9093 (solo 127.0.0.1)
```

## R2-29 · Logs JSON con correlationId de punta a punta

- Los tres servicios (y el consumidor nuevo) escriben **una línea JSON por evento** con el formato
  Logstash nativo de Spring Boot (`logging.structured.format.console`), más `service` y `replica`.
- `correlationId`: nace en NGINX (`X-Request-Id`, generado si no viene o si no tiene un formato
  seguro) → `CorrelationIdFilter` lo pone en el MDC y lo devuelve en la respuesta → viaja en las
  llamadas gateway→wellbeing (cabecera), en los frames STOMP (`x-request-id` o el del handshake,
  `StompMdcInterceptor`) y en cada evento de Redis (campo `correlationId`; el gateway lo restaura
  al procesarlo). `userId` (id interno) se agrega una vez autenticada la petición.
- Revisión de PII: se quitaron del log el cuerpo de las respuestas de chat rechazadas y los mensajes de
  excepciones de Jackson (incluían parte del contenido); la auditoría solo registra ids. Los eventos de
  notificación (que traen nombres) nunca se registran.

Traza real (`X-Request-Id: obs-traza-1794458368`, administrador que intenta entrar al Wellbeing Domain):

| Dónde | Qué se ve |
|---|---|
| NGINX (log JSON) | `{"correlationId":"obs-traza-1794458368","uri":"/api/wellbeing/psicologos","status":404,"upstream":"172.19.0.23:8081"}` |
| wellbeing réplica 2 (log JSON) | `logger_name=zeal.security.audit`, `correlationId=obs-traza-1794458368`, `replica=987a60d27f20`, `event=ACCESO_DENEGADO userId=usr-admin-001` |
| `security_audit` | `ACCESO_DENEGADO · DENEGADO · usr-admin-001 · obs-traza-1794458368` |
| Loki | `{service="wellbeing"} |= "obs-traza-1794458368"` devuelve la línea, con `level` como etiqueta y `correlation_id`/`replica` como metadatos |

## R2-30 · Métricas técnicas

`/actuator/prometheus` en los tres servicios (solo red interna: NGINX responde 404 a `/actuator`):
histogramas HTTP por endpoint (`http_server_requests_seconds_bucket`, para p95), etiquetas `service` y
`replica`, JVM, pool de conexiones (HikariCP), conexiones WebSocket (`zeal_realtime_websocket_sessions`,
`zeal_realtime_websocket_users`), latencia de eventos commit → STOMP
(`zeal_realtime_delivery_latency_seconds`, R2-24), excepciones no controladas
(`zeal_errors_unexpected_total{exception}`) y reutilización de sesiones (`zeal_security_refresh_reuse_total`).

Prometheus descubre las réplicas por DNS (`dns_sd_configs`); objetivos durante el ensayo:

```
business-metrics 172.19.0.17:8084 up      postgres  postgres-exporter-marketplace:9187 up
marketplace      172.19.0.18:8082 up      postgres  postgres-exporter-wellbeing:9187 up
marketplace      172.19.0.22:8082 up      rabbitmq  rabbitmq:15692 up
realtime         172.19.0.24:8083 up      redis     redis-exporter:9121 up
realtime         172.19.0.25:8083 up      cadvisor  cadvisor:8080 up
wellbeing        172.19.0.19:8081 up
wellbeing        172.19.0.23:8081 up
```

## R2-31 · Métricas de negocio — demostración de MANT-2

Consumidor **nuevo** `services/zeal-business-metrics` (Spring Boot, propio `pom.xml`, Dockerfile y CI
`.github/workflows/business-metrics.yml`). Se suscribe a los canales de Redis que ya existían y deriva:

| Métrica | Fuente (evento existente, sin cambios) |
|---|---|
| `zeal_business_appointments_total{outcome="reservada|cancelada"}` | `zeal.notifications` (`RESERVA_CONFIRMADA`, `CITA_CANCELADA`) |
| `zeal_business_slots_opened_total` | `zeal.wellbeing.slots` (`CREADA`) |
| `zeal_business_freed_slots_taken_total` | `zeal.wellbeing.freed-slots.taken` |
| `zeal_business_applications_total{status}` | `zeal.marketplace.applications` |
| `zeal_business_workshop_enrollments_total` | `zeal.marketplace.enrollments` |
| `zeal_business_published_total{kind}` | `zeal.marketplace.projects.published`, `…workshops.published` |
| `zeal_business_users_active` (gauge) | conjunto de presencia del gateway en Redis (solo lectura) |
| `zeal_business_events_total{channel}` | todos (uso por funcionalidad del lado del servidor) |

Deduplica por `eventId` (`SET NX`) para poder correr varias réplicas. Prueba:
`DomainEventMetricsTest` (eventos reales copiados de lo que publican los productores; un duplicado se
cuenta una vez). En el ensayo contó la actividad real: `applications{ACEPTADA}=100`, `{EN_ESPERA}=333`,
`published{convocatoria}=1`.

**0 líneas en los productores por R2-31:** el módulo vive en su propia carpeta y se integra solo por los
canales de Redis; ningún archivo de wellbeing ni marketplace lo referencia
(`grep -rl "business-metrics|DomainEventMetrics" zeal-wellbeing-service/src zeal-marketplace-service/src` → 0).
Al hacer el commit de R2-31 por separado (ver propuesta de commits del reporte final):

```bash
git -C zeal-infra-compose show --stat <commit R2-31>           # solo services/zeal-business-metrics/**, CI y compose
git -C zeal-wellbeing-service diff --stat <antes> <después>     # vacío: el commit no existe en los productores
git -C zeal-marketplace-service diff --stat <antes> <después>   # vacío
```

Dos métricas que **no** viajan en ningún evento se cuentan donde ocurren y son parte de R2-30, no de R2-31:
inicios de sesión (`zeal_business_logins_total{role}`, wellbeing) y mensajes de chat
(`zeal_business_chat_messages_total{role}`, wellbeing; nunca el contenido). El uso del lado del
cliente llega por R2-32.

## R2-32 · Telemetría del cliente

`POST /api/telemetria` en el gateway (contrato: `docs/contratos/telemetria.md`): validación estricta
sin texto libre, 16 KB máximo (413), 20 eventos máximo, límite de 30 envíos/min por persona en Redis
(429, compartido entre réplicas), nombres fuera de la lista → `otro` (cardinalidad acotada), ruta solo
en el log. Pruebas: `TelemetryApiIT`. Por NGINX: `POST /api/telemetria` → 202 y
`zeal_frontend_errors_total{name="error_api"} 1` en Prometheus.

## R2-33 · Stack de monitoreo

| Componente | Archivo |
|---|---|
| Prometheus + reglas | `monitoring/prometheus/prometheus.yml`, `alerts.yml` (`promtool check rules`: 5 reglas OK) |
| Alertmanager | `monitoring/alertmanager/alertmanager.yml` (`amtool check-config` OK); local: receptor de prueba `alert-sink` |
| Loki + Alloy | `monitoring/loki/loki.yml`, `monitoring/alloy/config.alloy` (logs de Docker; `level` como etiqueta, `correlation_id` y `replica` como metadatos) |
| cAdvisor, exportadores de PostgreSQL y Redis | `docker-compose.monitoring.yml` |
| Grafana | datasources y tablero **"ZEAL · Estado de la plataforma"** provisionados (`monitoring/grafana/`): réplicas arriba por componente, alertas activas, p95 y errores por servicio, peticiones/s, latencia commit → STOMP, conexiones WebSocket, negocio, errores del frontend, revocaciones SEG-4 y logs de error |

Multinodo: `deploy/nodes/monitoring/` (Prometheus con `file_sd` generado por `render-targets.sh` desde
las IPs privadas, Alertmanager con el canal real, Loki, Grafana en `/grafana` tras el borde con
`GF_SERVER_SERVE_FROM_SUB_PATH`) y `monitoring-agent.yml` (cAdvisor + Alloy en cada nodo).

### Alertas medidas en el ensayo

| Alerta | Cómo se provocó | Resultado | Objetivo |
|---|---|---|---|
| `TasaDeErroresAlta` (OBS-1) | carga constante de 20 req/s y la base de marketplace detenida | *pending* a los 25 s, **disparada a los 146 s**, en Alertmanager como "> 1 % de errores 5xx en **marketplace**" | ≤ 3 min, nombra el componente |
| `ReutilizacionDeSesion` (SEG-4, R2-15) | `tests/security/seg4-session-theft.sh` | en Alertmanager **14 s** después de la reutilización; entregada al receptor en **≤ 26 s** | < 1 min |
| Recuperación | se reinició la base | marketplace volvió a *ready* solo, sin reinicios (liveness no depende de la base) | — |

Para identificar el componente en ≤ 5 min: la alerta trae `job`; el tablero muestra en la primera fila
qué componente tiene réplicas caídas, su p95 y su tasa de errores, y el panel de logs filtra por
`service`/`level` (con el `correlationId` se sigue una petición concreta).

## Pendiente de cowork

Desplegar `deploy/nodes/monitoring` y el agente en cada nodo, generar los objetivos con las IPs reales,
conectar el canal real de Alertmanager, proteger Grafana (contraseña fuerte; opcional: restricción por IP
de oficina en el Caddy del borde) y repetir las dos pruebas de alerta sobre el despliegue distribuido.
