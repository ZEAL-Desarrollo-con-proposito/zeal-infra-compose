# Contrato · Login con Microsoft, renovación y cierre de sesión (HU-BE-22)

**Servicio:** wellbeing · **Tareas:** R2-17, R2-12, R2-13 · **Escenarios:** SEG-2, SEG-4 · **Decisiones:** ADR-07 (OIDC + PKCE, BFF)

ZEAL ya **no maneja contraseñas**: Microsoft autentica (código + PKCE; el backend es cliente confidencial)
y ZEAL solo admite las cuentas precargadas por cada empresa (se busca por correo). La sesión de ZEAL es un
access token JWT de **15 min** (en memoria del SPA) + un **refresh token rotativo** en cookie `httpOnly`.

> `POST /api/auth/login` (correo + contraseña) **se retiró**: ahora responde 404. Ver "Cambios" al final.

## 1. Iniciar el login

`POST /api/auth/microsoft` · sin token · `Content-Type: application/json`

```json
{ "remember": true, "returnTo": "/empleado/mis-citas" }
```

| Campo | Regla |
|---|---|
| `remember` | `true` → la cookie de renovación sobrevive al cierre del navegador (30 días); `false` → cookie de sesión (y la sesión vence a las 12 h aunque el navegador siga abierto). |
| `returnTo` | Ruta **interna** del SPA a la que volver (empieza con `/`, sin `//`, `\`, esquema ni host). Vacía → `/`. Cualquier otra cosa → **400**. |

Respuesta `200` (`Cache-Control: no-store`) + `Set-Cookie: zeal_oidc=…; Path=/api/auth/microsoft; HttpOnly; Secure; SameSite=Lax; Max-Age=600`:

```json
{ "authorizationUrl": "https://login.microsoftonline.com/<tenant>/oauth2/v2.0/authorize?client_id=…&response_type=code&redirect_uri=…&scope=openid%20profile%20email&state=…&nonce=…&code_challenge=…&code_challenge_method=S256" }
```

El SPA navega a esa URL (`window.location.assign(authorizationUrl)`). La petición debe ir con
`credentials: 'include'` para que el navegador guarde la cookie del flujo.

> TODO(ZEAL-REVIEW): no se encontró el PR de FE con este flujo; la forma `{ authorizationUrl }` es la
> elegida por el backend. Si el PR espera otro nombre de campo, es un cambio de una línea.

## 2. Regreso desde Microsoft (lo maneja el navegador, no el SPA)

`GET /api/auth/microsoft/callback?code=…&state=…` (o `?error=access_denied&state=…`)

El backend valida `state` (contra la cookie del flujo), canjea el código con PKCE y el secreto del
cliente, valida el ID token (firma con las JWKS de Microsoft, emisor, audiencia = nuestro client id,
vigencia y `nonce`), busca la cuenta por correo y responde **302**:

| Resultado | `Location` | Cookies |
|---|---|---|
| Cuenta registrada | `<frontend>/<returnTo>` | `zeal_refresh=…; Path=/api/auth; HttpOnly; Secure; SameSite=Strict` (+ `Max-Age` si `remember`) |
| Cuenta no registrada en ZEAL | `<frontend>/login?error=cuenta_no_registrada` | — |
| La persona canceló en Microsoft | `<frontend>/login?error=cancelado` | — |
| Cualquier otra falla (state/nonce/firma/emisor/audiencia inválidos, flujo vencido, proveedor caído) | `<frontend>/login?error=fallo` | — |

Siempre se borra `zeal_oidc`. El mensaje no indica nada más (no revela qué cuentas existen más allá
de lo que el propio código implica). Todos los intentos quedan en `security_audit`.

## 3. Obtener / renovar el access token

`POST /api/auth/refresh` · sin cuerpo · con la cookie `zeal_refresh` (`credentials: 'include'`)

Respuesta `200` (misma forma que el antiguo login, ya validada por `isLoginResponse()`) + nueva cookie `zeal_refresh` (rotada):

```json
{
  "accessToken": "eyJhbGciOiJIUzI1NiJ9…",
  "tokenType": "Bearer",
  "expiresIn": 900,
  "user": { "id": "usr-empleado-001", "fullName": "David Cajamarca", "email": "david.cajamarca@nexura.co",
            "role": "EMPLEADO", "organization": "Nexura S.A.S." }
}
```

| Código | Cuándo |
|---|---|
| `200` | Cookie válida: se entrega access token nuevo y la cookie se **reemplaza** (la anterior deja de servir). |
| `401` | Sin cookie, cookie inválida/vencida o sesión revocada. Se borra la cookie. Mensaje: "Tu sesión terminó. Vuelve a iniciar sesión." |

**Uso esperado:** al cargar el SPA después del callback (no hay access token en memoria) y antes de que
venza el actual (`expiresIn`). **Una sola renovación a la vez** (single-flight entre pestañas, p. ej. con
`BroadcastChannel`/`navigator.locks`): presentar dos veces la misma cookie se trata como **robo** (SEG-4) y
revoca toda la sesión. El servidor tiene un margen configurable `REFRESH_REUSE_GRACE` (0 s por defecto).

**SEG-4:** si alguien presenta una cookie ya usada, se revoca la sesión completa: esa petición y la
siguiente del dueño reciben 401, todos los access tokens de la sesión dejan de servir en los tres
servicios en < 1 s y el gateway cierra las conexiones STOMP de esa sesión (el cliente debe volver a `/login`).

## 4. Cerrar sesión

`POST /api/auth/logout` · con la cookie `zeal_refresh` · `204` siempre (idempotente) y borra la cookie.
Revoca la sesión en el servidor (sus access tokens dejan de servir y el gateway cierra sus sockets).

## 5. Access token

JWT HS256 de 15 min. Claims: `sub` (id), `role`, `fullName`, `email`, `organization`, **`jti`** y
**`sid`** (nuevos; identifican el token y la sesión). Las APIs y el CONNECT STOMP lo rechazan con 401 si
venció o fue revocado.

## 5b. Bloqueo por fuerza bruta (SEG-1) — respuestas que debe manejar el frontend

El bloqueo lo hace el borde (NGINX + CrowdSec), antes de llegar al backend. Aplica a `/api/` (el SPA siempre carga).

| Código | Cuándo | Cabeceras / cuerpo |
|---|---|---|
| **429** | La IP superó el límite de intentos de login (`POST /api/auth/microsoft` o `GET /api/auth/microsoft/callback`: ~60 por minuto, ráfaga de 20) | `Retry-After: 60` (segundos) · `{"status":429,"error":"Too Many Requests","message":"Demasiados intentos desde esta red. Intenta de nuevo en un minuto."}` |
| **403** | CrowdSec bloqueó la IP por fuerza bruta (más de 10 fallos de login) — vale para **cualquier** ruta `/api/` | `Retry-After: 300` (segundos) · `{"status":403,"error":"Forbidden","message":"Acceso bloqueado desde esta red."}` |

- Un intento fallido ya **no** es un 401: es el callback que redirige a `/login?error=cuenta_no_registrada`,
  `/login?error=fallo` o `/login?error=cancelado`. Eso es lo que cuenta CrowdSec.
- El bloqueo dura 30 min (el `Retry-After` del 403 es una pista de reintento, no la duración exacta).
- Las empresas detrás de un mismo NAT comparten IP: un bloqueo afecta a todas sus personas.

## 6. CORS y cookies

- Producción: SPA y API en el mismo origen (NGINX) → no hay CORS.
- Desarrollo (SPA en `http://localhost:3000`, API en `http://localhost:8080`): `/api/**` responde con
  `Access-Control-Allow-Credentials: true` para los orígenes de `CORS_ALLOWED_ORIGINS`. Las cookies son
  `Secure`; los navegadores las aceptan en `http://localhost`.

## 7. Desarrollo local

`docker compose up` incluye un proveedor OIDC de prueba en `http://localhost:8090`. En su pantalla de
login se escribe cualquier usuario y, en *claims*, el correo de una cuenta semilla:
`{"email": "david.cajamarca@nexura.co"}`.

## Cambios respecto al MVP

| Antes | Ahora |
|---|---|
| `POST /api/auth/login {email, password}` → token de 24 h | Retirado (404). Login con `POST /api/auth/microsoft` + callback |
| Token de 24 h sin renovación | Access token de 15 min + `POST /api/auth/refresh` con cookie rotativa |
| Sin cierre de sesión en el servidor | `POST /api/auth/logout` revoca la sesión |
| — | `jti` y `sid` en el access token |
