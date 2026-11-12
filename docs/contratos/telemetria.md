# Contrato · Telemetría del cliente (R2-32, HU-BE-25)

**Servicio:** realtime-gateway · **Ruta pública:** `POST /api/telemetria` (por NGINX, mismo origen que el SPA)

El frontend envía errores, uso por funcionalidad y latencias percibidas. El servidor los convierte en
métricas Prometheus (para tableros y alertas) y en logs estructurados **sin datos personales**.

## Petición

`POST /api/telemetria` · `Authorization: Bearer <access token>` · `Content-Type: application/json` ·
cuerpo de **16 KB como máximo** con `Content-Length` (lo que envían `fetch` y `navigator.sendBeacon` con un `Blob`).

```json
{
  "events": [
    { "type": "error",    "name": "chunk_load",            "route": "/empleado/mis-citas" },
    { "type": "uso",      "name": "reservar_cita" },
    { "type": "latencia", "name": "notificacion_recibida", "valueMs": 180 }
  ]
}
```

| Campo | Regla |
|---|---|
| `events` | 1 a **20** eventos por envío (agrupar y enviar cada ~30 s o al ocultar la pestaña) |
| `type` | `error` · `uso` · `latencia` |
| `name` | `^[a-z0-9_]{1,40}$`. Nombres reconocidos (fuera de esta lista se cuentan como `otro`): `error_js`, `error_api`, `chunk_load`, `ws_desconectado`, `video_fallo`, `login`, `reservar_cita`, `cancelar_cita`, `chat_enviado`, `postular`, `inscribir_taller`, `entrar_sala`, `entrar_taller`, `tomar_cupo`, `carga_inicial`, `notificacion_recibida`, `mensaje_recibido`, `api_respuesta` |
| `route` | Opcional. Ruta del SPA **sin identificadores**: `^(/[a-z-]{1,30}){0,4}/?$` (p. ej. `/empleado/sala`, no `/empleado/sala/reserva-123`) |
| `valueMs` | Solo para `latencia`: 0 a 120000 |

**No hay campos de texto libre**: ni mensajes de error, ni stack traces, ni correos, nombres o
contenido de chat. Si se necesita depurar un error, se usa el `X-Request-Id` de la respuesta fallida.

## Respuestas

| Código | Cuándo |
|---|---|
| `202` | Aceptado (sin cuerpo) |
| `400` | Validación (`ApiError` con el primer motivo) |
| `401` | Sin token o token inválido/revocado |
| `413` | Cuerpo de más de 16 KB o sin `Content-Length` |
| `429` | Más de 30 envíos por minuto de la misma persona (límite compartido entre réplicas, en Redis). Reintentar en el siguiente minuto; no reintentar en bucle |

## Latencia de los avisos en vivo (`emittedAt`)

Todo mensaje STOMP que publica el gateway (`/topic/...` y `/user/queue/...`, sin excepción) trae en la raíz
**`emittedAt`**: instante ISO-8601 UTC en que el servidor lo publicó (p. ej. `"2026-11-12T16:41:47.093Z"`).
El frontend calcula `ahora - emittedAt` al pintarlo y lo envía como evento `latencia`:

```json
{ "events": [
  { "type": "latencia", "name": "notificacion_recibida", "valueMs": 180 },
  { "type": "latencia", "name": "mensaje_recibido",      "valueMs": 95 }
] }
```

- Un evento por aviso medido (o la muestra que el cliente decida), **máximo 20 por envío** y un envío cada
  ~30 s (límite de 30 envíos/min por persona; más allá, 429).
- Los relojes del navegador y del servidor pueden diferir: un `valueMs` negativo se descarta en el cliente
  (el servidor rechaza valores fuera de 0–120000 con 400).
- El histograma `{ "type": "LATENCIA_EN_VIVO", "series": [...] }` **no** es parte de este contrato: el
  endpoint lo rechaza con 400. Se acordó adaptar el frontend a `{ "events": [...] }`.

## Qué se mide (para tableros)

| Evento | Métrica Prometheus | Etiquetas |
|---|---|---|
| `error` | `zeal_frontend_errors_total` | `name` |
| `uso` | `zeal_frontend_usage_total` | `name` |
| `latencia` | `zeal_frontend_latency_seconds` (histograma: p50/p95/p99) | `name` |

Cada evento deja además una línea de log JSON con `type`, `name`, `route`, `valueMs`, el `userId`
interno (nunca correo ni nombre) y el `correlationId`.
