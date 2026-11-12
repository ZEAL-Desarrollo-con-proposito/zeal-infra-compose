# Evidencia SEG · Seguridad (HU-BE-21, HU-BE-22) — SEG-2, SEG-3, SEG-4

> Escenarios aprobados: **SEG-2** (autenticación), **SEG-3** (autorización sobre recursos ajenos) y
> **SEG-4** (una sola sesión válida por cookie de renovación). SEG-1 y SEG-5 quedan fuera.
> Ensayo local (2026-11-11) con `docker-compose.yml`: 2 réplicas por servicio, proveedor OIDC de prueba
> (mock-oauth2-server) en lugar de Microsoft Entra ID. Ejecución oficial sobre el despliegue
> distribuido: ver `docs/cowork/CHECKLIST_COWORK.md`.

## Qué se implementó

| Tarea | Dónde | Resumen |
|---|---|---|
| R2-14 Auditoría de solo inserción | `V5__security_audit_and_app_role.sql` (wellbeing), `V3__…` (marketplace); `SecurityAudit`, `DeniedAccessAudit`, `GatewayAuditListener` | Tabla `security_audit` (usuario = id interno, IP, hora, tipo, resultado, correlationId, detalle sin PII). Trigger que impide UPDATE/DELETE/TRUNCATE a **cualquier** usuario; el rol de la aplicación (separado del propietario que corre Flyway) solo tiene INSERT/SELECT. Cada registro va en su propia transacción y también al log. El gateway (sin base) envía sus eventos por Redis y una sola réplica de wellbeing los inserta |
| R2-17 Login con Microsoft | `auth/AuthService`, `auth/oidc/*`, `auth/AuthController` | Código + PKCE S256, cliente confidencial, `state`/`nonce`/verificador en cookie firmada `httpOnly` `SameSite=Lax` de 10 min. ID token validado contra las JWKS (firma), `iss`, `aud`, `exp`, `nonce`. Solo cuentas precargadas (por correo). Ruta de regreso solo interna. Se retiró `POST /api/auth/login` y la columna `password_hash` (V6). Issuer/tenant, client id y secreto por variables |
| R2-12 Refresh rotativo | `auth/session/*`, V6 | Familias por inicio de sesión; solo el hash SHA-256 del token; cada uso rota; rotación atómica `UPDATE … WHERE used_at IS NULL` (entre réplicas pasa una sola petición); reutilizar uno usado revoca la familia. Access token de 15 min con `jti` y `sid`. `remember` → cookie persistente (30 d) o de sesión (12 h) |
| R2-13 Lista negra | `TokenRevocations` (wellbeing), `RevocationValidator` (los tres servicios), `RevokedSessionCloser` + `LiveSockets` (gateway) | Redis por `sid` y por `jti` con TTL = vigencia restante; consultada en el filtro de seguridad de los tres servicios y en el CONNECT STOMP; la revocación se difunde por Pub/Sub y cada réplica del gateway cierra los sockets de ese token |
| R2-8 / R2-10 SEG-3 | `SecurityConfig`, `JsonSecurityErrorHandler`, `GlobalExceptionHandler`; consultas filtradas por dueño | Todo acceso denegado → 404 + auditoría. Se movió el filtro de dueño/empresa a la consulta en: sala de la cita (`findForParticipant`), activar sala (`findOfPsychologistForUpdate`), tomar cupo liberado (`findOfferedToForUpdate`), sala del taller (`findByIdAndOrganization`) |
| R2-9 STOMP | `StompSubscriptionGuard`, `StompAuthenticationInterceptor`, `GatewaySecurityAudit` | Token validado en CONNECT (incluida la lista negra); SUBSCRIBE a colas de otro usuario o tópicos de otra empresa rechazado y auditado |
| R2-15 Alerta SEG-4 | Métrica `zeal_security_refresh_reuse_total` (`SessionService`) + regla en `monitoring/prometheus/alerts.yml` | Ver Bloque 5 / `OBS.md` |

## SEG-2 · Autenticación (R2-11)

**Pruebas automatizadas** — `zeal-wellbeing-service/.../auth/MicrosoftLoginIT.java` (proveedor OIDC de
prueba en Testcontainers):

| Prueba | Verifica |
|---|---|
| `everyRegisteredAccountSignsInAndLandsOnItsReturnPath` | **100 %** de las cuentas semilla (11) entra, vuelve a su ruta interna, recibe la cookie `HttpOnly; Secure; SameSite=Strict; Path=/api/auth` y el callback responde en **≤ 1 s** |
| `unregisteredAccountIsRejectedWithAGenericMessageAndAudited` | cuenta no registrada → `/login?error=cuenta_no_registrada`; auditoría con IP, hora y correlationId, sin correo |
| `wrongAudienceIsRejected`, `wrongIssuerIsRejected` | ID token con otra audiencia / otro emisor → `error=fallo` |
| `idTokenSignedByAnotherKeyIsRejected` | ID token firmado con otra clave que dice venir del emisor correcto → rechazado |
| `nonceThatDoesNotMatchTheFlowIsRejected`, `alteredStateIsRejected`, `callbackWithoutTheFlowCookieFails` | nonce, state o flujo inválidos → `error=fallo` |
| `cancellingAtMicrosoftReturnsToLoginWithCancelled` | `error=access_denied` → `error=cancelado` |
| `externalReturnPathsAreRejected` (6 casos) | `https://…`, `//…`, `/\…`, `javascript:`, `/%5C…`, ruta relativa → 400 |

**De punta a punta por NGINX** — `tests/security/seg2-login.mjs`:

```
OK   cuenta registrada entra y vuelve a su ruta http://localhost:3000/empleado/mis-citas
OK   cookie de renovación httpOnly, Secure, SameSite=Strict, Path=/api/auth 
OK   callback ≤ 1 s (27 ms)
OK   refresh entrega access token de 15 min 
OK   el access token sirve en la API 
OK   cuenta no registrada → /login?error=cuenta_no_registrada 
OK   ruta de regreso externa rechazada 
OK   POST /api/auth/login retirado (403)

8/8 verificaciones · RESULTADO: APROBADO
```

## SEG-3 · Autorización sobre recursos ajenos (R2-8, R2-9, R2-10)

Matriz rol × recurso en el CI (`./mvnw verify`):

- `zeal-wellbeing-service/.../security/AuthorizationMatrixIT.java`: **44 casos** (cita, sala, activar sala,
  cancelar, chat, agenda, franjas, directorio, cupos liberados, empleados de la empresa) × {empleado dueño,
  empleado de la misma empresa, empleado de otra empresa, psicólogo de la cita, otro psicólogo,
  administradores de ambas empresas}. Todo lo ajeno → 404.
- `zeal-marketplace-service/.../security/AuthorizationMatrixIT.java`: **23 casos** (convocatoria, postulación,
  inscripción, sala del taller, paneles de administración, listados propios) × {empleado/administrador de
  la empresa dueña y de otra, psicólogo} + `catalogsNeverListAnotherCompanysOffers` (0 datos ajenos en los
  catálogos y paneles).
- `WellbeingApiSecurityIT.adminNeverReachesTheWellbeingDomainAndGets404`: 4 rutas → 404 y 4 registros
  `ACCESO_DENEGADO` en la auditoría.
- STOMP: `TwoReplicasIT.foreignSubscriptionsAreRejectedAndAudited` y `RealtimeGatewayIT.organizationTopicsAreClosedToOtherCompanies`.

Resultado: **100 % de los accesos no autorizados de la matriz denegados; 0 datos ajenos expuestos.**

## SEG-4 · Una sola sesión válida (R2-12, R2-13, R2-16)

**Pruebas automatizadas** — `RefreshSessionIT` (wellbeing) y `TwoReplicasIT` (gateway):

| Prueba | Verifica |
|---|---|
| `eachRenewalRotatesTheCookieAndTheOldOneStopsWorking` | cada renovación entrega otra cookie |
| `reusingAnOldRefreshTokenRevokesTheWholeSessionEverywhere` | reutilizar una cookie usada → 401; la cookie legítima y todos los access tokens de la sesión dejan de servir; métrica +1; difusión por Redis; auditoría `REFRESH_REUTILIZADO` |
| `concurrentRenewalsWithTheSameTokenLetExactlyOneThrough` | 12 renovaciones simultáneas con la misma cookie → **exactamente 1** `200` (rotación atómica) |
| `logoutRevokesTheSessionAndClearsTheCookie` | logout revoca y borra la cookie |
| `refreshTokensAreStoredOnlyAsHashes` | la base nunca guarda el token en claro |
| `revokingASessionClosesItsStompConnectionsOnEveryReplicaWithinOneSecond` (gateway) | dos réplicas: las conexiones STOMP del token revocado se cierran en ambas en < 1 s; las demás siguen; el token ya no conecta |
| `SecurityAuditIT` | la app no puede UPDATE/DELETE/TRUNCATE/DROP en la auditoría; el trigger lo impide incluso al propietario; los eventos del gateway llegan por Redis una sola vez |

**Robo de sesión con dos réplicas por servicio** — `tests/security/seg4-session-theft.sh` (login real
por el proveedor OIDC de prueba; consulta directa a cada réplica):

```
OK   la víctima renueva su sesión 
OK   STOMP conectado en 2 réplicas del gateway 
OK   el access token funciona en todas las réplicas antes del robo [200,200,200,200,200,200]
OK   reutilizar el refresh token se rechaza (401) 
OK   REST: 401 en las 6 réplicas (47 ms)
OK   REST: en < 1 s 
OK   STOMP: conexiones cerradas en todas las réplicas (22 / 22 ms)
OK   STOMP: en < 1 s 
OK   la sesión completa quedó revocada (la cookie legítima tampoco sirve) 

9/9 verificaciones · RESULTADO: APROBADO
OK   auditoría: REFRESH_REUTILIZADO registrado (1)
```

**Aviso a operadores en < 1 min:** la métrica `zeal_security_refresh_reuse_total` dispara la alerta
`ReutilizacionDeSesion` de Prometheus (`for: 0m`, evaluación cada 15 s) → Alertmanager/Grafana. Ver
`OBS.md`. El canal real (correo, Teams…) es cowork.

## Cómo repetirlo

```bash
cd zeal-wellbeing-service && ./mvnw verify          # SEG-2, SEG-3, SEG-4 (unitarias + integración)
cd zeal-marketplace-service && ./mvnw verify        # matriz SEG-3 del Business Domain
cd zeal-realtime-gateway && ./mvnw verify           # STOMP: CONNECT, SUBSCRIBE, revocación en 2 réplicas
cd zeal-infra-compose && docker compose up -d --build
node tests/security/seg2-login.mjs
./tests/security/seg4-session-theft.sh
```

## Pendiente de cowork

Registrar la app en Microsoft Entra ID (URI de redirección `https://<dominio>/api/auth/microsoft/callback`,
secreto, tenant), cargar `OIDC_*` en los nodos de servicios, repetir `seg2-login` (con una cuenta real de
prueba) y `seg4-session-theft` sobre el despliegue distribuido, y conectar el canal real de la alerta.
