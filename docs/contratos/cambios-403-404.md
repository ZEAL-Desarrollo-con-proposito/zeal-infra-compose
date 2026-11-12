# Contrato · 403 → 404 ante accesos denegados (HU-BE-21, SEG-3)

**Servicios:** wellbeing y marketplace · **Tareas:** R2-8, R2-10

Un usuario autenticado que pide un recurso de otra persona, de otra empresa o de un rol que no es el
suyo recibe **404**, igual que si el recurso no existiera: así no se puede averiguar qué existe. Antes
recibía 403 en varios casos.

| Caso | Antes | Ahora |
|---|---|---|
| Administrador (ADMIN) en cualquier ruta del Wellbeing Domain (`/api/wellbeing/**`, `/api/chats/**`) — HU-BE-11 | 403 "No tienes permiso para esta operación." | **404** "El recurso solicitado no existe." |
| Empleado en endpoints de psicólogo (`/api/wellbeing/franjas/**`, `/api/wellbeing/reservas/agenda`, `…/sala/activar`) | 403 | **404** |
| Psicólogo/administrador en endpoints de empleado (`/api/wellbeing/psicologos`, `/api/wellbeing/reservas/mias`, `/api/wellbeing/cupos`, `/api/proyectos/**`, `/api/talleres` …) | 403 | **404** |
| Empleado o psicólogo en `/api/organizacion/empleados` o `/api/admin/**` | 403 | **404** |
| Recurso de otra persona/empresa (cita, sala, chat, oferta de cupo, convocatoria, taller, sala del taller) | 404 | 404 (sin cambio; ahora el filtro va en la consulta) |
| Sin token o token vencido/revocado | 401 | 401 (sin cambio) |

Cuerpo del 404 (el mismo `ApiError` de siempre):

```json
{ "status": 404, "error": "Not Found", "message": "El recurso solicitado no existe.", "path": "/api/wellbeing/psicologos", "timestamp": "…" }
```

**Impacto en FE:** la pantalla de "acceso denegado" (HU-FE-11) ya no se activa por un 403 del servidor;
el SPA sigue protegiendo las rutas por rol en el cliente. Un 404 en una ruta del rol equivocado debe
tratarse como "no encontrado" / volver al inicio.

**STOMP (R2-9):** suscribirse a una cola privada ajena o a un tópico de otra empresa sigue cerrando la
sesión STOMP con un frame ERROR (sin cambio de contrato); ahora además queda auditado.

Cada intento denegado (HTTP y STOMP) queda en `security_audit` con el id interno del usuario, IP, hora y
correlationId.
