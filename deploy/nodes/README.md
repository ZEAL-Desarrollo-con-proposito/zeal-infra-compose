# Despliegue en Azure (R2-4) — una VM por microservicio, un `docker-compose.yml` por VM

| VM | Carpeta | Servicios | IP pública | Puertos que expone (NSG) |
|---|---|---|---|---|
| Borde | `edge/` | Caddy (TLS) + NGINX (balanceador) | Sí | 80, 443 desde Internet; 8080 desde la VM de realtime |
| Web | `web/` | SPA (frontend) | No | 80 desde borde |
| wellbeing | `wellbeing/` | wellbeing ×2 (8081, 8091) | No | desde borde y monitoreo |
| marketplace | `marketplace/` | marketplace ×2 (8082, 8092) | No | desde borde y monitoreo |
| realtime | `realtime/` | realtime-gateway ×2 (8083, 8093) | No | desde borde y monitoreo |
| Datos | `data/` | PostgreSQL ×2, Redis, RabbitMQ, respaldos | No | 5432, 5433, 6379, 61613 desde microservicios; exportadores desde monitoreo |
| Medios | `media/` | LiveKit, coturn | Sí | 443/tcp, 3478, 7881/tcp, 49160-49200/udp, 50000-50100/udp desde Internet; 7880 desde borde |
| Monitoreo | `monitoring/` | Prometheus, Loki, Grafana, Alertmanager, métricas de negocio | No | 3000 desde borde; 3100 desde la VNet |

Cada carpeta tiene `.env.example`: copiarlo como `.env` en su VM y completar. Para tolerar la caída de una VM
completa se agrega una segunda VM del microservicio (runbook, paso 12). Las
imágenes vienen de GitHub Container Registry (R2-6). El orden de arranque y los comandos exactos están en
`docs/cowork/RUNBOOK_DESPLIEGUE_MULTINODO.md`. Nada de esto se ejecutó contra Azure.

Todos los servicios internos publican sus puertos **solo en la IP privada** del nodo
(`${PRIVATE_IP}:puerto:puerto`), nunca en 0.0.0.0.
