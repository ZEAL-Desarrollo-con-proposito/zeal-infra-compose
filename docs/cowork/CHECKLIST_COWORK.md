# Checklist cowork · Lo que solo se puede hacer con la infraestructura real y el equipo reunido

Lista consolidada de todo lo `[COWORK]` y la parte cowork de lo `[LOCAL + COWORK]`. Lo local ya está
implementado y probado (ver `docs/evidencias/`). Orden sugerido: el del `RUNBOOK_DESPLIEGUE_MULTINODO.md`.

| ✔ | Tarea | Origen | Qué hacer | Hecho cuando… |
|---|---|---|---|---|
| ☐ | Red, subredes, NSG, VMs, DNS privado | R2-4 | Revisar y ejecutar `deploy/azure/provision.sh` | 7 VMs, solo borde y medios con IP pública; `zeal.internal` con los registros A |
| ☐ | DNS público | R2-4, DT-5 | `zeal.<dominio>` → borde, `turn.<dominio>` → medios | `dig` resuelve ambos |
| ☐ | Docker y repo en cada nodo | R2-4 | Paso 2 del runbook | `docker compose version` en las 7 VMs |
| ☐ | Nodo de datos | R2-5 | Paso 3 | PostgreSQL ×2, Redis y RabbitMQ *healthy*; roles `zeal_owner`/`zeal_app` |
| ☐ | Respaldo diario programado | R2-5 | `crontab` con `pg-backup.sh` | Archivos `.dump` del día en `/var/backups/zeal` y rotación de 14 días |
| ☐ | Prueba de restauración real | R2-5 | `pg-restore-test.sh` de ambas bases | "OK: todas las tablas … tienen las mismas filas" |
| ☐ | Certificado TLS real de TURN | DT-5 | certbot para `turn.<dominio>` → `/etc/zeal/turn-certs` | `openssl s_client -connect turn.<dominio>:443` muestra el certificado |
| ☐ | IP pública del nodo de medios en coturn y LiveKit | DT-5 | `.env` del nodo de medios | `docker compose logs coturn` muestra la IP externa |
| ☐ | Reglas NSG de medios | DT-5 | 3478 UDP/TCP, 443 TCP, 49160-49200 UDP, 50000-50100 UDP, 7881 TCP | `turn-check.sh` desde fuera de la VNet en OK |
| ☐ | Relé forzado desde red sin UDP | DT-6 | `turn-check.sh` (TCP/TLS) y `tools/turn-check/index.html` (candidatos relay y sala de LiveKit con `iceTransportPolicy: relay`) | Candidatos `relay` y videollamada 1:1 conectada solo por el relé |
| ☐ | Videollamada 1:1 por LiveKit en el SPA | DT-8 | Probar con el PR de FE desplegado | Empleado y psicólogo se ven y se oyen; chat y salida funcionan |
| ☐ | Nodos de servicios | R2-4 | Paso 6 (services-1, luego services-2) | Las 8 réplicas *ready*; Prometheus las ve `up` |
| ☐ | Nodos web y borde | R2-4 | Paso 7 | `https://zeal.<dominio>/gateway/health` → UP; `/actuator/*` → 404 |
| ☐ | Balanceo entre nodos | R2-2 | 10 peticiones y mirar `upstream` en el log de NGINX | Tráfico en 10.20.2.4 y 10.20.2.5 |
| ☐ | Registrar la app en Entra ID | R2-17 | Paso 9 (redirect de producción, secreto, claim `email`) | Login de una cuenta precargada entra; una no precargada vuelve con `cuenta_no_registrada` |
| ☐ | Secretos y entorno `production` en GitHub | R2-6 | `DEPLOY_SSH_KEY`, `DEPLOY_KNOWN_HOSTS`, `BASTION_HOST`, `SERVICES_1_HOST`, `SERVICES_2_HOST` en los 3 repos; revisores del entorno | `Deploy` corre sin error de autenticación |
| ☐ | Llave del pipeline en los nodos | R2-6 | `zeal_deploy.pub` en borde y servicios | `ssh -J deploy@edge deploy@10.20.2.4 true` desde fuera |
| ☐ | Primera ejecución del pipeline | R2-6 | `Run workflow` en cada servicio | services-1 → readiness → services-2; imágenes en GHCR con el SHA |
| ☐ | Prueba de reversión del pipeline | R2-6 | Desplegar un SHA que no arranca (p. ej. con `DB_URL` inválida en un entorno de prueba) | `deploy-service.sh` vuelve a la versión anterior y el job falla en services-1 sin tocar services-2 |
| ☐ | Organización y proyectos en SonarCloud | R2-18 | Importar los 3 repos (`ZEAL-Desarrollo-con-proposito_<repo>`), análisis automático **desactivado** (lo hace el CI) | Primer análisis con cobertura de JaCoCo visible |
| ☐ | Secreto `SONAR_TOKEN` | R2-18 | Secreto de organización en GitHub | El paso "Análisis SonarCloud" corre y espera el Quality Gate |
| ☐ | Quality Gate "ZEAL" | R2-20 | Condiciones sobre código nuevo: Reliability, Security y Maintainability **A**, Security Hotspots revisados 100 %, **Coverage ≥ 80 %**, Duplicated lines ≤ 3 %; asignarlo a los 3 proyectos | Visible como gate por defecto de los proyectos |
| ☐ | Protección de `main` | R2-20 | En cada repo: requerir PR, checks `verify` y `SonarCloud Code Analysis` en verde, rama al día, sin push directo | Un PR con cobertura < 80 % no se puede fusionar |
| ☐ | Revisar hallazgos de SonarCloud | R2-21 | Primer análisis: confirmar A; resolver o justificar los `EI_EXPOSE_REP` que marque | Calificación A en los 3 proyectos |
| ☐ | Monitoreo en su nodo | R2-33 | Paso 5 + agente en cada nodo | Prometheus con todos los objetivos `up`; logs de los 7 nodos en Loki |
| ☐ | Grafana tras el borde | R2-33 | `/grafana` en el Caddy del borde, contraseña fuerte (opcional: IP de oficina) | `https://zeal.<dominio>/grafana` pide login; tablero "ZEAL · Estado de la plataforma" con datos |
| ☐ | Canal real de alertas | R2-15, R2-33 | URL del webhook (Teams/Discord/Slack) o SMTP en `alertmanager.yml` del nodo de monitoreo | Alerta de prueba (`amtool alert add prueba`) llega al canal |
| ☐ | DISP-1 oficial | R2-7 | Carga desde otra máquina + caída del proceso de una réplica de cada servicio | `DISP.md` completo: 0 errores visibles, < 60 s, 0 perdidas |
| ☐ | DISP-2 oficial | R2-7 | Duplicar la carga y agregar una réplica (nodo o registro A) | Recibe tráfico < 2 min; p95 ≤ 500 ms |
| ☐ | SEG-4 en el despliegue distribuido | R2-16 | `seg4-session-theft` contra las 8 réplicas | Acceso cae en < 1 s en REST y STOMP; auditoría y alerta < 1 min |
| ☐ | Login real (SEG-2) | R2-11 | Cuenta de prueba de Entra ID: entra, no registrada, cancelar | Las tres rutas de `/login?error=…` y la auditoría con IP real |
| ☐ | REND-1 / REND-2 / estrés oficiales | R2-28 | Scripts k6 desde una máquina distinta a los servicios | `REND.md` completo; REND-2 con p95 ≤ 1 s (ver nota de `REND.md` si no) |
| ☐ | Alertas OBS-1 y SEG-4 en producción | R2-33 | Provocar ambas (base detenida con carga; refresh reutilizado) | Alerta en ≤ 3 min / < 1 min en el canal real, nombrando el componente |
| ☐ | Datos de demostración | — | `DEMO_DATA_ENABLED=false` en producción; cargar las cuentas reales por empresa | Ninguna cuenta semilla en producción |
| ☐ | Repositorio del consumidor de métricas | R2-31 | Decidir si `services/zeal-business-metrics` pasa a su propio repo (hoy vive en infra) y su pipeline a GHCR | Imagen `zeal-business-metrics` publicada y desplegada en los nodos de servicios |
