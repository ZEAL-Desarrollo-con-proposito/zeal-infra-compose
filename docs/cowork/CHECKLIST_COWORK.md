# Checklist cowork · Lo que solo se puede hacer con la infraestructura real y el equipo reunido

Lista consolidada de todo lo `[COWORK]` y la parte cowork de lo `[LOCAL + COWORK]`. Lo local ya está
implementado y probado (ver `docs/evidencias/`). Orden sugerido: el del `RUNBOOK_DESPLIEGUE_MULTINODO.md`.

| ✔ | Tarea | Origen | Qué hacer | Hecho cuando… |
|---|---|---|---|---|
| ☐ | Red, subredes, NSG, VMs, DNS privado | R2-4 | Revisar y ejecutar `deploy/azure/provision.sh` | 12 VMs repartidas en las 4 cuentas (microservicios y front en dos VMs), IP públicas anotadas en `peers.env`, reglas de NSG aplicadas |
| ☐ | DNS público | R2-4, DT-5 | `zeal.<dominio>` → borde, `turn.<dominio>` → medios | `dig` resuelve ambos |
| ☐ | Docker y repo en cada nodo | R2-4 | Paso 2 del runbook | `docker compose version` en las 8 VMs |
| ☐ | Nodo de datos | R2-5 | Paso 3 | PostgreSQL ×2, Redis y RabbitMQ *healthy*; roles `zeal_owner`/`zeal_app` |
| ☐ | Respaldo diario programado | R2-5 | `crontab` con `pg-backup.sh` | Archivos `.dump` del día en `/var/backups/zeal` y rotación de 14 días |
| ☐ | Prueba de restauración real | R2-5 | `pg-restore-test.sh` de ambas bases | "OK: todas las tablas … tienen las mismas filas" |
| ☐ | Certificado TLS real de TURN | DT-5 | certbot para `turn.<dominio>` → `/etc/zeal/turn-certs` | `openssl s_client -connect turn.<dominio>:443` muestra el certificado |
| ☐ | IP pública del nodo de medios en coturn y LiveKit | DT-5 | `.env` del nodo de medios | `docker compose logs coturn` muestra la IP externa |
| ☐ | Reglas NSG de medios | DT-5 | 3478 UDP/TCP, 443 TCP, 49160-49200 UDP, 50000-50100 UDP, 7881 TCP | `turn-check.sh` desde fuera de la VNet en OK |
| ☐ | Relé forzado desde red sin UDP | DT-6 | `turn-check.sh` (TCP/TLS) y `tools/turn-check/index.html` (candidatos relay y sala de LiveKit con `iceTransportPolicy: relay`) | Candidatos `relay` y videollamada 1:1 conectada solo por el relé |
| ☐ | Videollamada 1:1 por LiveKit en el SPA | DT-8 | Probar con el PR de FE desplegado | Empleado y psicólogo se ven y se oyen; chat y salida funcionan |
| ☐ | Frontend con login de Microsoft | R2-17 | Fusionar en el repo de FE el flujo de `docs/contratos/auth-microsoft.md` (el `main` actual usa `POST /api/auth/login`, ya retirado) | Se puede iniciar sesión desde el SPA |
| ☐ | Dos VMs por microservicio | R2-4 | Paso 6 (wellbeing, marketplace, realtime: VM 1 y VM 2) | Las 6 VMs *ready* (8081, 8082, 8083) |
| ☐ | Apagar una VM de servicio o del front (la prueba de la evaluación) | R2-4, DISP-1 | Paso 11 del runbook, con carga ligera | Sin errores visibles; todo el tráfico en la otra VM; al encender la apagada vuelve sola |
| ☐ | Nodos web y borde | R2-4 | Paso 7 | `https://zeal.<dominio>/gateway/health` → UP; `/actuator/*` → 404 |
| ☐ | Balanceo entre nodos | R2-2 | 10 peticiones y mirar `upstream` en el log de NGINX | Tráfico en los puertos 808x y 809x de la VM de cada microservicio |
| ☐ | Registrar la app en Entra ID | R2-17 | Paso 9 (redirect de producción, secreto, claim `email`) | Login de una cuenta precargada entra; una no precargada vuelve con `cuenta_no_registrada` |
| ☐ | Secretos y entorno `production` en GitHub | R2-6 | `DEPLOY_SSH_KEY`, `DEPLOY_KNOWN_HOSTS`, `BASTION_HOST`, `SERVICE_HOST` (IP de la VM de ese microservicio) en los 3 repos; revisores del entorno | `Deploy` corre sin error de autenticación |
| ☐ | Llave del pipeline en los nodos | R2-6 | `zeal_deploy.pub` en el borde y en las 3 VMs de microservicios | `ssh -J deploy@edge deploy@10.20.2.4 true` desde fuera |
| ☐ | Primera ejecución del pipeline | R2-6 | `Run workflow` en cada servicio | réplica a → readiness → réplica b; imágenes en GHCR con el SHA |
| ☐ | Prueba de reversión del pipeline | R2-6 | Desplegar un SHA que no arranca (p. ej. con `DB_URL` inválida en un entorno de prueba) | `deploy-service.sh` vuelve a la versión anterior y el job falla sin tocar la réplica b (ensayado en local) |
| ☐ | Organización y proyectos en SonarCloud | R2-18 | Importar los 3 repos (`ZEAL-Desarrollo-con-proposito_<repo>`), análisis automático **desactivado** (lo hace el CI) | Primer análisis con cobertura de JaCoCo visible |
| ☐ | Secreto `SONAR_TOKEN` | R2-18 | Secreto de organización en GitHub | El paso "Análisis SonarCloud" corre y espera el Quality Gate |
| ☐ | Quality Gate "ZEAL" | R2-20 | Condiciones sobre código nuevo: Reliability, Security y Maintainability **A**, Security Hotspots revisados 100 %, **Coverage ≥ 80 %**, Duplicated lines ≤ 3 %; asignarlo a los 3 proyectos | Visible como gate por defecto de los proyectos |
| ☐ | Protección de `main` | R2-20 | En cada repo: requerir PR, checks `verify` y `SonarCloud Code Analysis` en verde, rama al día, sin push directo | Un PR con cobertura < 80 % no se puede fusionar |
| ☐ | Revisar hallazgos de SonarCloud | R2-21 | Primer análisis: confirmar A; resolver o justificar los `EI_EXPOSE_REP` que marque | Calificación A en los 3 proyectos |
| ☐ | Monitoreo en su nodo | R2-33 | Paso 5 + agente en cada nodo | Prometheus con todos los objetivos `up`; logs de las 8 VMs en Loki |
| ☐ | Grafana tras el borde | R2-33 | `/grafana` en el Caddy del borde, contraseña fuerte (opcional: IP de oficina) | `https://zeal.<dominio>/grafana` pide login; tablero "ZEAL · Estado de la plataforma" con datos |
| ☐ | Canal real de alertas | R2-15, R2-33 | URL del webhook (Teams/Discord/Slack) o SMTP en `alertmanager.yml` del nodo de monitoreo | Alerta de prueba (`amtool alert add prueba`) llega al canal |
| ☐ | DISP-1 oficial | R2-7 | Carga desde otra máquina + caída del proceso de una réplica de cada servicio | `DISP.md` completo: 0 errores visibles, < 60 s, 0 perdidas |
| ☐ | DISP-2 oficial | R2-7 | Duplicar la carga y agregar una réplica (nodo o registro A) | Recibe tráfico < 2 min; p95 ≤ 500 ms |
| ☐ | SEG-4 en el despliegue distribuido | R2-16 | `seg4-session-theft` contra las 6 réplicas | Acceso cae en < 1 s en REST y STOMP; auditoría y alerta < 1 min |
| ☐ | Login real (SEG-2) | R2-11 | Cuenta de prueba de Entra ID: entra, no registrada, cancelar | Las tres rutas de `/login?error=…` y la auditoría con IP real |
| ☐ | REND-1 / REND-2 / estrés oficiales | R2-28 | Scripts k6 desde una máquina distinta a los servicios | `REND.md` completo; REND-2 con p95 ≤ 1 s (ver nota de `REND.md` si no) |
| ☐ | Alertas OBS-1 y SEG-4 en producción | R2-33 | Provocar ambas (base detenida con carga; refresh reutilizado) | Alerta en ≤ 3 min / < 1 min en el canal real, nombrando el componente |
| ☐ | Datos de demostración | — | `DEMO_DATA_ENABLED=false` en producción; cargar las cuentas reales por empresa | Ninguna cuenta semilla en producción |
| ☐ | Repositorio del consumidor de métricas | R2-31 | Decidir si `services/zeal-business-metrics` pasa a su propio repo (hoy vive en infra) y su pipeline a GHCR | Corre en la VM de monitoreo (se construye allí desde el repo de infraestructura) |
| ☐ | CrowdSec en el borde (SEG-1) | HU-BE-20 | `CROWDSEC_BOUNCER_KEY` en el `.env` del borde; `cscli bouncers list` muestra a `nginx` | El bouncer consulta cada pocos segundos |
| ☐ | IP real del cliente detrás de Caddy | HU-BE-20 | `jq .remoteAddr` del log de NGINX con una petición desde fuera | Es la IP del cliente, no la de Caddy ni 172.x |
| ☐ | Prueba de fuerza bruta en el despliegue real (tarea 437) | HU-BE-20 | `tests/security/seg1-bruteforce.sh` adaptado (`ZEAL_API=https://zeal.<dominio>`; el `X-Forwarded-For` simulado no funciona desde Internet: usar dos máquinas/redes distintas) | Una IP con 100 intentos/min queda con 429 y luego 403; otra IP entra normal; la alerta aparece en `cscli alerts list` |
| ☐ | Enrolar CrowdSec (opcional) | ADR-15 | Quitar `DISABLE_ONLINE_API` y `cscli console enroll` con la cuenta del equipo | Comparte y recibe listas de IP maliciosas |
| ☐ | Variante de 4 cuentas | R2-4 | Sección "Variante: 4 cuentas" del runbook: `provision-account.sh`, `peers.env`, `.env` con IP públicas | Las 8 VMs se ven entre sí solo por los puertos de cada regla |

