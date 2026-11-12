# Despliegue multinodo (R2-4) — un `docker-compose.yml` por nodo

| Nodo | Carpeta | Servicios | IP pública | Puertos que expone (NSG) |
|---|---|---|---|---|
| Borde | `edge/` | Caddy (TLS) + NGINX (balanceador) | Sí | 80, 443 desde Internet |
| Web | `web/` | SPA (frontend) | No | 80 desde borde |
| Servicios 1 y 2 | `services/` (el mismo en ambos) | wellbeing, marketplace, realtime-gateway (1 réplica de cada uno por nodo) | No | 8081-8083 desde borde; 8081-8083 desde monitoreo (métricas) |
| Datos | `data/` | PostgreSQL ×2, Redis, RabbitMQ, respaldos | No | 5432, 5433, 6379, 61613 desde servicios; 15692/9187/9121 desde monitoreo |
| Medios | `media/` | LiveKit, coturn | Sí | 443/tcp, 3478/udp+tcp, 7881/tcp, 49160-49200/udp, 50000-50100/udp desde Internet; 7880 desde borde |
| Monitoreo | `monitoring/` | Prometheus, Loki, Alloy, Grafana | No | 3000 desde borde (Grafana tras el borde) |

Cada carpeta tiene `.env.example`: copiarlo como `.env` en el nodo (`/opt/zeal/`) y completar. Las
imágenes vienen de GitHub Container Registry (R2-6). El orden de arranque y los comandos exactos están en
`docs/cowork/RUNBOOK_DESPLIEGUE_MULTINODO.md`. Nada de esto se ejecutó contra Azure.

Todos los servicios internos publican sus puertos **solo en la IP privada** del nodo
(`${PRIVATE_IP}:puerto:puerto`), nunca en 0.0.0.0.
