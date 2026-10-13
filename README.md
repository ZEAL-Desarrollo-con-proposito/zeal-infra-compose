# zeal-infra-compose

Orquestación local de ZEAL: bases de datos por bounded context, broker de eventos, API Gateway y
pruebas de sustentación de los retos de concurrencia y tiempo real.

| Componente | Puerto | Rol |
|---|---|---|
| `api-gateway` (NGINX) | 8080 | Punto de entrada único del frontend (`VITE_API_BASE_URL=http://localhost:8080`) |
| `postgres-wellbeing` | 5432 | Wellbeing Domain (citas, chat: datos clínicos aislados) |
| `postgres-marketplace` | 5433 | Business Domain (convocatorias y talleres) |
| `redis-broker` | 6379 | Message Bus (Pub/Sub) y notificaciones |
| `livekit` | 7881/tcp, 50000-50100/udp | SFU de las videollamadas grupales de los talleres (señalización por el gateway en `/livekit`) |
| `zeal-wellbeing-service` | 8081 | corre en el host |
| `zeal-marketplace-service` | 8082 | corre en el host |
| `zeal-realtime-gateway` | 8083 | corre en el host (STOMP/SockJS en `/ws`) |

## Arranque

```bash
docker compose up -d && docker compose ps      # esperar "healthy"
(cd ../zeal-wellbeing-service   && ./mvnw spring-boot:run)
(cd ../zeal-marketplace-service && ./mvnw spring-boot:run)
(cd ../zeal-realtime-gateway    && ./mvnw spring-boot:run)
curl -s localhost:8080/gateway/health
```

## Enrutamiento del API Gateway

| Prefijo | Servicio |
|---|---|
| `/api/auth`, `/api/wellbeing`, `/api/chats`, `/api/organizacion` | wellbeing (8081) |
| `/api/proyectos`, `/api/postulaciones`, `/api/talleres`, `/api/inscripciones`, `/api/admin` | marketplace (8082) |
| `/api/notificaciones`, `/api/presencia`, `/ws` | realtime-gateway (8083) |
| `/livekit/` | livekit (7880, WebSocket; se quita el prefijo) |

## Pruebas de sustentación

Con todo levantado (y `DEMO_DATA_ENABLED=true`, el valor por defecto):

```bash
node tests/concurrency/c1-overbooking.mjs      # 500 postulaciones → 10 ACEPTADA, 490 EN_ESPERA, occupied=10
node tests/concurrency/c2-double-booking.mjs   # 100 reservas a la misma franja → 1×201, 99×409
node tests/concurrency/c3-freed-slot-race.mjs  # 50 candidatos por un cupo liberado → 1×200, 49×409
(cd tests/realtime && npm install && npm test) # RT-1 (latencia del chat), RT-2 y RT-3, 22 verificaciones
```

Las pruebas de carga firman tokens con el secreto de **desarrollo** para simular cientos de
personas distintas; no funcionan (ni deben funcionar) contra un entorno con otro `JWT_SECRET`.
Cada ejecución crea su propia convocatoria/franjas, así que se pueden repetir.

## Datos

Los servicios usan esquemas propios (`wellbeing`, `marketplace`) gestionados con Flyway. Las tablas
del esquema `public` de versiones anteriores ya no se usan; si quieres empezar de cero:
`docker compose down -v` (borra los volúmenes).

## Despliegue en producción (un servidor con Docker)

`docker-compose.prod.yml` levanta **todo** en contenedores: las dos bases de datos, Redis, los tres
microservicios, el frontend compilado, el API Gateway (NGINX) y Caddy para el HTTPS. Solo Caddy
expone puertos (80/443); lo demás vive en la red interna de Docker.

```
Internet ──443──▶ Caddy (TLS) ──▶ api-gateway (NGINX :8080) ─┬─ /api/auth, /api/wellbeing, /api/chats ─▶ wellbeing
                                                              ├─ /api/proyectos, /api/talleres, ...  ─▶ marketplace
                                                              ├─ /api/notificaciones, /ws          ─▶ realtime
                                                              ├─ /livekit/  (señalización de video) ─▶ livekit (SFU)
                                                              └─ /                                  ─▶ frontend (SPA)
Internet ──UDP 50000-50100 / TCP 7881──▶ livekit  (audio y video de los talleres)
```

### Requisitos del servidor

- Linux con Docker Engine 24+ y el plugin `docker compose` (2 vCPU y 4 GB de RAM son suficientes).
- Puertos 80 y 443 abiertos, más **7881/tcp y 50000-50100/udp** para el video de los talleres
  (LiveKit). Con TURN, además 3478/udp+tcp y 49160-49200/udp.
- Un dominio cuyo registro DNS `A` apunte a la IP del servidor. Si no tienes uno, usa
  `<ip-con-guiones>.sslip.io` (p. ej. `203-0-113-10.sslip.io`). **El HTTPS es obligatorio**: el
  navegador solo enciende la cámara y el micrófono de la sala de video en un origen seguro.

### Pasos

```bash
mkdir zeal && cd zeal
for repo in zeal-infra-compose zeal-wellbeing-service zeal-marketplace-service zeal-realtime-gateway zeal-frontend-client; do
  git clone git@github.com:ZEAL-Desarrollo-con-proposito/$repo.git
done
cd zeal-infra-compose
cp .env.prod.example .env.prod   # completa dominio, PUBLIC_URL y secretos (openssl rand -base64 48)
docker compose -f docker-compose.prod.yml --env-file .env.prod up -d --build
docker compose -f docker-compose.prod.yml --env-file .env.prod ps   # todo "healthy" en ~2 min
curl -s https://TU-DOMINIO/gateway/health
```

Para actualizar: `git pull` en cada repositorio y repetir el `up -d --build`. Los datos persisten
en los volúmenes `zeal-prod_*`. NGINX lee su configuración como archivo montado: si cambió
`nginx/nginx.prod.conf`, recrea el gateway para que tome la nueva:

```bash
docker compose -f docker-compose.prod.yml --env-file .env.prod up -d --force-recreate api-gateway
```

Con `DEMO_DATA_ENABLED=true` los servicios siembran psicólogos, citas, convocatorias y talleres con
fechas relativas al primer arranque. Los usuarios de demostración son los de la migración `V2`
(contraseña `Zeal2026*`). Para regenerar la demo con fechas frescas antes de una presentación:

```bash
docker compose -f docker-compose.prod.yml --env-file .env.prod down -v   # ⚠ borra todos los datos
docker compose -f docker-compose.prod.yml --env-file .env.prod up -d
```

### Videollamadas grupales de los talleres (LiveKit)

Los talleres tienen sala de video grupal. Marketplace firma el permiso de entrada (solo para la
empresa anfitriona y las personas inscritas). El navegador se conecta a LiveKit por el gateway
(`wss://TU-DOMINIO/livekit`) y envía el audio y el video directo a la VM por UDP 50000-50100, o
por TCP 7881 si su red bloquea UDP.

1. En `.env.prod` define `LIVEKIT_API_SECRET` (`openssl rand -hex 32`).
2. Abre los puertos en el firewall de la VM. En Azure: **VM → Redes → Agregar regla de puerto de
   entrada**, una para `7881` TCP y otra para `50000-50100` UDP. O con la CLI:
   `az vm open-port -g rg-zeal -n vm-zeal --port 7881,50000-50100 --priority 920`.
3. `docker compose -f docker-compose.prod.yml --env-file .env.prod up -d --build`.

LiveKit descubre la IP pública de la VM por STUN. Para probar el stack en un equipo local (sin IP
pública) agrega `LIVEKIT_USE_EXTERNAL_IP=false` y `LIVEKIT_NODE_IP=127.0.0.1`.

### Videollamadas detrás de redes restrictivas (TURN)

Con solo STUN, dos personas detrás de NAT simétrico o de un firewall corporativo pueden no lograr
conectar el video. El perfil `turn` añade un relé coturn en el mismo servidor:

```bash
# en .env.prod
TURN_URLS=turn:TU-DOMINIO:3478?transport=udp,turn:TU-DOMINIO:3478?transport=tcp
TURN_USERNAME=zeal
TURN_CREDENTIAL=<openssl rand -hex 16>
PUBLIC_IP=<IP pública del servidor>

docker compose -f docker-compose.prod.yml --env-file .env.prod --profile turn up -d
```
