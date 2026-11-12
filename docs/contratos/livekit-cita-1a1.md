# Contrato · Sala de LiveKit de la cita 1:1 (DT-7 / DT-8)

**Servicio:** wellbeing · **Historia:** HU-DT-02 · **Decisión:** ADR-14 (la cita 1:1 pasa a LiveKit, un solo camino de medios)
**Para:** equipo de frontend (PR de la sala 1:1 con el cliente de LiveKit de los talleres)

La cita 1:1 usa **el mismo patrón y la misma forma** que la sala de los talleres
(`GET /api/talleres/{id}/sala` → `connection: { serverUrl, token } | null`), así que el componente
de LiveKit de los talleres se reutiliza tal cual. Lo que **no** cambia:

- El psicólogo sigue siendo quien activa la sala (`POST /api/wellbeing/reservas/{id}/sala/activar`).
- La sala de espera, los estados (`PROGRAMADA`, `ACTIVA`, `FINALIZADA`, `CANCELADA`) y el aviso
  `SALA_ACTUALIZADA` por `/user/queue/salas` cuando el psicólogo activa.
- El chat de la llamada (sigue siendo la conversación 1:1 de wellbeing, `/app/chats/{id}/mensajes`).

## 1. Vista de la sala (recomendado)

`GET /api/wellbeing/reservas/{reservationId}/sala` · `Authorization: Bearer <access token>`

Respuesta `200` (campos nuevos en **negrita**; el resto no cambia):

```json
{
  "reservationId": "reserva-7f3c…",
  "status": "ACTIVA",
  "startsAt": "2026-11-12T14:00:00Z",
  "endsAt": "2026-11-12T14:50:00Z",
  "opensAt": "2026-11-12T13:50:00Z",
  "closesAt": "2026-11-12T14:50:00Z",
  "participant": { "id": "usr-psicologo-001", "fullName": "Laura Martínez" },
  "iceServers": [
    { "urls": "stun:stun.l.google.com:19302" },
    { "urls": "turn:turn.zeal.co:3478?transport=udp", "username": "1794416400:usr-empleado-001", "credential": "7xeTHjtYqTI7mte…" },
    { "urls": "turns:turn.zeal.co:443?transport=tcp", "username": "1794416400:usr-empleado-001", "credential": "7xeTHjtYqTI7mte…" }
  ],
  "connection": { "serverUrl": "/livekit", "token": "eyJhbGciOiJIUzI1NiIs…" }
}
```

| Campo | Regla |
|---|---|
| **`connection`** | `{ serverUrl, token }` **solo** si: quien pide es uno de los dos participantes **y** la sala está `ACTIVA` (la activó el psicólogo) **y** `opensAt ≤ ahora < endsAt`. En cualquier otro caso `null`. |
| `connection.serverUrl` | URL del servidor de LiveKit. Relativa (`/livekit`) cuando el SPA y la API comparten origen; el cliente la convierte a `wss://<host>/livekit`, igual que en los talleres. |
| `connection.token` | JWT de LiveKit para **esta persona y esta sala**: `sub` = id de la persona, `name` = nombre, `metadata` = `{"role":"PSICOLOGO"\|"EMPLEADO"}`, `video.room` = `cita-{reservationId}`, `roomAdmin` = `true` solo para el psicólogo. Vence en `endsAt`. |
| `iceServers` | Se mantiene para el cliente WebRTC punto a punto mientras se migra. Las credenciales TURN ahora son **temporales** (vencen en 2 h) en lugar de fijas; la forma no cambia. Con LiveKit no hace falta usarlas: LiveKit entrega su propio TURN (el mismo coturn) al conectar. |

**Nombre de la sala:** determinístico, `cita-{reservationId}`. Los dos participantes entran a la misma sala.

**Cuándo volver a pedir la vista:** al recibir `{"type":"SALA_ACTUALIZADA","reservationId":…}` por
`/user/queue/salas` (el psicólogo activó), igual que hoy. Si `connection` llega `null`, mostrar la
sala de espera.

## 2. Solo el permiso de entrada (alternativa estricta)

`GET /api/wellbeing/reservas/{reservationId}/sala/conexion` · `Authorization: Bearer <access token>`

| Código | Cuándo | Cuerpo |
|---|---|---|
| `200` | Participante, sala `ACTIVA` y dentro de la ventana | `{ "serverUrl": "/livekit", "token": "…" }` |
| `404` | **Cualquier otro caso**: no participa, la reserva no existe, la sala no está activa, aún no abre, ya cerró o fue cancelada. No distingue el motivo (SEG-3). | `{"status":404,"error":"Not Found","message":"Esta sesión no existe o no es tuya."}` |
| `401` | Sin token o token inválido/vencido | error estándar |

Útil para reintentar la conexión sin recargar toda la vista.

## 3. Códigos de error de la vista

| Código | Cuándo |
|---|---|
| `200` | Participante de la cita (con `connection` o `null` según las reglas) |
| `404` | La reserva no existe o la persona no participa en ella (incluye administradores de empresa desde HU-BE-21) |
| `401` | Sin token o token inválido/vencido |

`POST …/sala/activar` (solo psicólogo) responde además `409` si la sala aún no abre, ya cerró o la
cita fue cancelada, y ahora su respuesta también trae `connection` para el psicólogo.

## 4. Cliente (referencia)

```ts
const room = await getRoom(reservationId);                 // vista de la sala
if (room.connection) {
  const url = new URL(room.connection.serverUrl, window.location.href);
  url.protocol = url.protocol === 'https:' ? 'wss:' : 'ws:';
  await liveKitRoom.connect(url.toString(), room.connection.token);   // mismo cliente que los talleres
}
```

Para probar en redes restrictivas: `liveKitRoom.connect(url, token, { rtcConfig: { iceTransportPolicy: 'relay' } })`
fuerza el relé TURN (ver `tools/turn-check/`).
