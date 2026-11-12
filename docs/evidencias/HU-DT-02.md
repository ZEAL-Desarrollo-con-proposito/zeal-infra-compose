# Evidencia HU-DT-02 · Conexión garantizada de la cita 1:1 (DT-5, DT-6, DT-7)

**Escenarios:** DISP-1 (medios), REND-1 · **Decisión:** ADR-14 · **Fecha:** 2026-11-11 · **Entorno:** `docker-compose.yml` local (Linux)

## DT-5 · coturn permanente con credenciales temporales

| Criterio | Cómo quedó |
|---|---|
| coturn corre siempre | Servicio `coturn` sin perfil en `docker-compose.yml` y `docker-compose.prod.yml` (`restart: unless-stopped`, health check con `turnutils_stunclient`) |
| También por TLS (443) | `--tls-listening-port=${TURN_TLS_PORT}`: 5349 en local y en el servidor único (donde Caddy ocupa el 443); **443 en el nodo de medios** del despliegue multinodo. Certificado autofirmado en local (`coturn/generate-dev-cert.sh`); certificados reales montados por volumen (`TURN_CERT_DIR`) → cowork |
| Credenciales temporales firmadas, no fijas | `--use-auth-secret --static-auth-secret=${TURN_SECRET}`. wellbeing emite `usuario = <vencimiento>:<id>`, `credencial = base64(HMAC-SHA1(TURN_SECRET, usuario))`, vigencia `TURN_CREDENTIAL_TTL` (2 h). Se retiraron `TURN_USERNAME`/`TURN_CREDENTIAL` |
| Rango de relé acotado | `--min-port=49160 --max-port=49200` (41 puertos UDP) |
| LiveKit usa este TURN | `rtc.turn_servers` (UDP 3478 y TLS) con el mismo `secret`; LiveKit genera credenciales temporales para cada participante. Se verificó que LiveKit 1.13.7 acepta `secret`/`ttl` (su parser es estricto: rechaza campos desconocidos) |
| El relé no alcanza la red interna (prod) | `--denied-peer-ip` para 10/8, 172.16/12 y 192.168/16; `--no-multicast-peers` |

Prueba unitaria del algoritmo con un vector calculado aparte con `openssl`:
`RoomPropertiesTest.turnCredentialsAreTemporaryAndSignedWithTheSharedSecret`.

## DT-6 · Prueba forzando el relé

`tools/turn-check/turn-check.sh` usa `turnutils_uclient -y`: el cliente habla consigo mismo **a través
de dos relés asignados por coturn**, sin camino directo posible (equivalente a `iceTransportPolicy: "relay"`).
Con `--from-wellbeing` además reserva una cita real por la API y prueba la credencial que wellbeing
entrega en `iceServers`.

```
$ ./tools/turn-check/turn-check.sh --from-wellbeing
TURN 127.0.0.1:3478 (TLS 5349)
OK   UDP con credencial temporal (REST API) (enviados=40 recibidos=40 por el relé)
OK   TCP con credencial temporal (enviados=40 recibidos=40 por el relé)
OK   TLS con credencial temporal (enviados=40 recibidos=37 por el relé)
OK   credencial falsa rechazada
     credencial emitida por wellbeing para usr-empleado-001 (vence 2026-11-11 20:46:34)
OK   UDP con la credencial que emite wellbeing (enviados=40 recibidos=40 por el relé)
RESULTADO: APROBADO
```

`tools/turn-check/index.html` es la versión de navegador: (1) junta candidatos con
`iceTransportPolicy: "relay"` y aprueba si coturn asigna candidatos `relay`; (2) entra a la sala de
LiveKit de una cita con `rtcConfig: { iceTransportPolicy: "relay" }`, publica una pista sintética y
aprueba si el par de candidatos seleccionado es `relay`. En este equipo Firefox headless no genera
candidatos ICE, así que la parte de navegador se ejecuta a mano (abrir el archivo en Chrome/Firefox
con escritorio) y en la sesión cowork desde una red que bloquee UDP (ver `docs/cowork/CHECKLIST_COWORK.md`).

## DT-7 · Token de LiveKit de la cita 1:1

`zeal-wellbeing-service/src/test/java/co/zeal/wellbeing/room/RoomLiveKitIT.java` (PostgreSQL real):

| Prueba | Regla |
|---|---|
| `connectionIsIssuedOnlyAfterThePsychologistActivatesTheRoom` | antes de activar: `connection: null` y `/conexion` 404; después: token con `sub`, `name`, `video.room = cita-{id}`, `roomAdmin=false` para el empleado; el psicólogo recibe el suyo |
| `theRoomNameIsDeterministicPerReservation` | los dos participantes reciben la misma sala `cita-{id}` |
| `anyoneButTheTwoParticipantsGets404` | otro empleado, otro psicólogo y una reserva inexistente → 404 |
| `outsideTheEntryWindowThereIsNoConnection` | sala activada pero terminada → `FINALIZADA`, sin conexión, 404; antes de abrir → no se puede activar (409) y 404 |

Contrato para FE: `docs/contratos/livekit-cita-1a1.md`.

## Pendiente de cowork

Certificado real del dominio de TURN, IP pública del nodo de medios, reglas del NSG
(3478 UDP/TCP, 443 TCP, 49160-49200 UDP) y repetir `turn-check.sh` y la página desde una red sin UDP.
