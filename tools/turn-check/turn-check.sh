#!/usr/bin/env bash
# DT-6: verifica que el relé TURN funcione forzando su uso (sin conexión directa posible).
# Usa turnutils_uclient (incluido en la imagen de coturn) para asignar relés y enviar tráfico a
# través de ellos por UDP, TCP y TLS, y comprueba que una credencial falsa se rechace.
#
#   TURN_HOST=127.0.0.1 TURN_SECRET=... TURN_TLS_PORT=5349 ./turn-check.sh
#   ./turn-check.sh --from-wellbeing     # además prueba las credenciales que emite wellbeing
#
# Cowork: repetir desde una red que bloquee UDP contra el nodo de medios real (TURN_HOST=<IP pública>,
# TURN_TLS_PORT=443): las pruebas TCP/TLS deben seguir en OK.
set -uo pipefail
cd "$(dirname "$0")" || exit 1
TURN_HOST="${TURN_HOST:-127.0.0.1}"
TURN_PORT="${TURN_PORT:-3478}"
TURN_TLS_PORT="${TURN_TLS_PORT:-5349}"
TURN_SECRET="${TURN_SECRET:-ZealTurnDevSecretOnlyForLocal}"
IMAGE="coturn/coturn:4.7"
failures=0

uclient() { docker run --rm --network host --entrypoint turnutils_uclient "$IMAGE" "$@" 2>&1; }

# -y: el cliente habla consigo mismo a través de DOS relés (ningún camino directo), -n mensajes.
relay_test() {
  local name="$1"; shift
  local out; out="$(timeout 40 bash -c "$(declare -f uclient); IMAGE=$IMAGE uclient -y -n 10 -m 1 $*")"
  local sent recv
  sent="$(grep -o 'tot_send_msgs=[0-9]*' <<<"$out" | tail -1 | cut -d= -f2)"
  recv="$(grep -o 'tot_recv_msgs=[0-9]*' <<<"$out" | tail -1 | cut -d= -f2)"
  # Basta con que el tráfico vuelva por el relé: la asignación y el reenvío funcionan. Con TLS el
  # cliente de prueba corta antes de recibir todo lo que tiene en vuelo, así que se informa la cifra.
  if [ -n "$recv" ] && [ "${recv:-0}" -gt 0 ]; then
    echo "OK   $name (enviados=$sent recibidos=$recv por el relé)"
  else
    echo "FAIL $name"; echo "$out" | grep -iE "error|fail|401|403" | head -3 | sed 's/^/     /'; failures=$((failures + 1))
  fi
}

reject_test() {
  local out; out="$(timeout 20 bash -c "$(declare -f uclient); IMAGE=$IMAGE uclient -y -n 2 -m 1 $*")"
  if grep -qiE "401|unauthori|wrong|cannot complete Allocation|error" <<<"$out" && ! grep -q "tot_recv_msgs=[1-9]" <<<"$out"; then
    echo "OK   credencial falsa rechazada"
  else
    echo "FAIL credencial falsa aceptada"; failures=$((failures + 1))
  fi
}

echo "TURN $TURN_HOST:$TURN_PORT (TLS $TURN_TLS_PORT)"
relay_test "UDP con credencial temporal (REST API)" -W "$TURN_SECRET" -u turn-check -e "$TURN_HOST" -p "$TURN_PORT" "$TURN_HOST"
relay_test "TCP con credencial temporal"            -t -W "$TURN_SECRET" -u turn-check -e "$TURN_HOST" -p "$TURN_PORT" "$TURN_HOST"
relay_test "TLS con credencial temporal"            -t -S -W "$TURN_SECRET" -u turn-check -e "$TURN_HOST" -p "$TURN_TLS_PORT" "$TURN_HOST"
reject_test -W "secreto-que-no-es" -u turn-check -e "$TURN_HOST" -p "$TURN_PORT" "$TURN_HOST"

if [ "${1:-}" = "--from-wellbeing" ]; then
  read -r user credential < <(node issued-credentials.mjs) || { echo "FAIL no se obtuvieron credenciales de wellbeing"; failures=$((failures + 1)); }
  if [ -n "${user:-}" ]; then
    echo "     credencial emitida por wellbeing para ${user#*:} (vence $(date -d @"${user%%:*}" '+%F %T'))"
    relay_test "UDP con la credencial que emite wellbeing" -u "$user" -w "$credential" -e "$TURN_HOST" -p "$TURN_PORT" "$TURN_HOST"
  fi
fi

[ "$failures" -eq 0 ] && echo "RESULTADO: APROBADO" || { echo "RESULTADO: FALLIDO ($failures)"; exit 1; }
