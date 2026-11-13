# Despliegue en Azure (R2-4) — 12 VMs, cada microservicio y el front en dos (principal y respaldo)

| VM | Carpeta | Qué corre | IP pública | Puertos que expone (NSG) |
|---|---|---|---|---|
| `edge` | `edge/` | Caddy (TLS) + NGINX (balanceador) + CrowdSec | Sí | 80/443 desde Internet; 8080 desde las VMs de realtime |
| `web-1`, `web-2` | `web/` | SPA (frontend), principal y respaldo | No\* | 80 desde el borde |
| `wellbeing-1`, `wellbeing-2` | `wellbeing/` | wellbeing (8081), principal y respaldo | No\* | desde borde y monitoreo |
| `marketplace-1`, `marketplace-2` | `marketplace/` | marketplace (8082), principal y respaldo | No\* | desde borde y monitoreo |
| `realtime-1`, `realtime-2` | `realtime/` | realtime-gateway (8083), principal y respaldo | No\* | desde borde y monitoreo |
| `data` | `data/` | PostgreSQL ×2, Redis, RabbitMQ, respaldos | No\* | 5432, 5433, 6379, 61613 desde las VMs de servicios; exportadores desde monitoreo |
| `media` | `media/` | LiveKit, coturn | Sí | 443/tcp, 3478, 7881/tcp, 49160-49200/udp, 50000-50100/udp desde Internet; 7880 desde borde |
| `monitoring` | `monitoring/` | Prometheus, Loki, Grafana, Alertmanager, métricas de negocio | No\* | 3000 desde borde; 3100 desde las demás VMs |

\* Con las VMs en cuentas de Azure distintas (`provision-account.sh`) todas llevan IP pública estática y cada puerto
se abre solo a las IP de las VMs que lo necesitan; con una sola cuenta (`provision.sh`) basta con una red privada.

Cada microservicio y el front corren en **dos VMs** (principal `-1` y respaldo `-2`, el mismo `docker-compose.yml`
y un `.env` casi igual) y el balanceador del borde reparte entre ambas: si una VM se apaga, la otra atiende todo.
El modo lo decide `UPSTREAM_2_FLAG` en el `.env` del borde (vacío = activo-activo, `backup` = respaldo estricto).

Cada carpeta tiene `.env.example`: copiarlo como `.env` en su VM y completar. Las imágenes vienen de GitHub
Container Registry (R2-6). El orden de arranque y los comandos exactos están en
`docs/cowork/RUNBOOK_DESPLIEGUE_MULTINODO.md`. Nada de esto se ejecutó contra Azure; el comportamiento de apagar
una VM se ensayó en local con `tests/disp/vm-failover.sh`.

Los puertos de cada VM se publican solo en su IP privada (`${PRIVATE_IP}:puerto:puerto`), nunca en `0.0.0.0`;
Azure traduce la IP pública a esa privada.
