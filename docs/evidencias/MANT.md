# Evidencia MANT · Mantenibilidad e inspección continua (HU-BE-23)

**MANT-1:** el 100 % de los cambios a `main` pasa por pruebas, JaCoCo y SonarCloud con resultado en ≤ 10 min;
no se integra nada con calificación < A o cobertura < 80 %. **MANT-2:** ver la sección de R2-31 en `OBS.md`.
Fecha: 2026-11-11.

## R2-19 · Cobertura con JaCoCo (los tres servicios)

`jacoco-maven-plugin` 0.8.16 en cada `pom.xml`: agente en las pruebas unitarias (surefire) y en las de
integración (failsafe, Testcontainers), fusión de ambos en `target/jacoco-merged.exec`, reporte XML en
`target/site/jacoco/jacoco.xml` (ruta configurada en `sonar.coverage.jacoco.xmlReportPaths`) y
**`jacoco:check` que hace fallar el build si la cobertura de líneas baja del 80 %**.

| Servicio | `./mvnw verify` | Pruebas | Líneas | Ramas |
|---|---|---|---|---|
| zeal-wellbeing-service | exit 0 | 102 | 81.7% | 59.6% |
| zeal-marketplace-service | exit 0 | 47 | 89.5% | 58.8% |
| zeal-realtime-gateway | exit 0 | 46 | 89.5% | 67.0% |

Medición final, con los cinco bloques (Fase 2) incluidos. Antes de agregar pruebas (mismas reglas): wellbeing 81.9 %, marketplace 75.3 %, realtime-gateway 78.3 %.

**Exclusiones (y por qué):** solo `*Application` (el `main` de Spring Boot) y `*Properties` (registros de
configuración sin lógica: Spring los llena desde el YAML). No se excluyen controladores, servicios,
interceptores ni DTO con lógica.

### Pruebas nuevas (R2-22 / R2-23), todas de comportamiento real

| Servicio | Prueba | Qué protege |
|---|---|---|
| wellbeing | `MicrosoftLoginIT`, `RefreshSessionIT`, `SecurityAuditIT`, `AuthorizationMatrixIT`, `RoomLiveKitIT`, `RoomPropertiesTest` | login OIDC, rotación y robo de sesión, auditoría inmutable, matriz SEG-3, LiveKit 1:1, credenciales TURN |
| marketplace | `AuthorizationMatrixIT`, `ApiErrorsAndRevocationIT`, `ClusterLockIT`, `ProjectDemoDataTest`, `WorkshopDemoDataTest` | matriz SEG-3, lista negra con tokens reales, formato de errores, coordinación entre réplicas, datos demo coherentes y sembrados una vez |
| realtime-gateway | `TwoReplicasIT` (11), `NotificationApiIT`, `RestWellbeingClientTest`, `BrokerDestinationsTest` | dos réplicas reales con RabbitMQ y Redis, revocación de sesiones STOMP, API de notificaciones, cliente HTTP con timeouts, traducción de destinos |

## R2-18 · SonarCloud en el CI

- `.github/workflows/ci.yml` (los tres repos): `./mvnw verify` (pruebas + JaCoCo + `jacoco:check`) y luego
  `sonar:sonar -Dsonar.qualitygate.wait=true` con `SONAR_TOKEN`; si el Quality Gate falla, el job falla.
  Sin el secreto el paso se omite (para no romper forks antes de la sesión cowork). `timeout-minutes: 10`.
- Configuración en el `pom.xml`: `sonar.organization`, `sonar.projectKey`
  (`ZEAL-Desarrollo-con-proposito_<repo>`), `sonar.host.url`, `sonar.coverage.jacoco.xmlReportPaths`,
  `sonar.coverage.exclusions`. `actionlint` sin hallazgos en los tres workflows.
- Tiempo local de `./mvnw verify` por servicio: 3-5 min (Testcontainers incluido).

## R2-21 · Hallazgos corregidos sin SonarCloud

Análisis local: `javac -Xlint:all` (0 advertencias) y SpotBugs 4.10.5.0 (`effort=Max`, `threshold=Medium`).

| Hallazgo | Dónde | Corrección |
|---|---|---|
| `DCN_NULLPOINTER_EXCEPTION` (capturar NPE para validar) | `OidcProvider.metadata()` | Validación explícita de los campos del documento de descubrimiento |
| `CT_CONSTRUCTOR_THROW` | `Slot` (constructor), `LoginFlowCookie` | Validación en la fábrica antes de construir; clase `final` |
| Contenido potencialmente sensible en logs | `SecurityAudit`, `GatewaySecurityAudit` | Solo id interno; nunca correo, nombre ni texto del chat |
| Filtro de dueño después de cargar (IDOR, también "Security Hotspot") | sala, activar sala, tomar cupo, sala del taller | Filtro en la consulta (ver `SEG.md`) |
| Clases sin uso tras el refactor | `LoginRequest`, `InvalidCredentialsException`, consultas sin filtro | Eliminadas |

**Pendiente de validar en SonarCloud:** 62 avisos `EI_EXPOSE_REP/EI_EXPOSE_REP2` de SpotBugs. Son en su
gran mayoría beans de Spring inyectados guardados en campos y records con listas inmutables
(`List.copyOf`): falsos positivos conocidos en Spring. Si SonarCloud marca alguno como *code smell* real,
se corrige en la primera ejecución del Quality Gate.

## R2-20 · Quality Gate obligatorio en main (cowork)

Pasos en `docs/cowork/CHECKLIST_COWORK.md` (sección MANT): Quality Gate "ZEAL" (calificaciones A en
código nuevo, cobertura ≥ 80 %, 0 hotspots sin revisar), asignarlo a los tres proyectos y regla de
protección de `main` que exige los checks `verify` (CI) y `SonarCloud Code Analysis`. No se modificó
la configuración de GitHub.
