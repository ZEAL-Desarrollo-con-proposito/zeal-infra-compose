#!/usr/bin/env bash
# SEG-1 (HU-BE-20, tarea 437) · Fuerza bruta contra el login con Microsoft, de punta a punta por NGINX:
#   1. Una IP con 100 intentos por minuto queda limitada: 429 con Retry-After.
#   2. Otra IP entra con normalidad.
#   3. CrowdSec detecta el ataque y lo REGISTRA (alerta + decisión de bloqueo) y el borde responde 403
#      con Retry-After a esa IP en /api/ (pero el sitio sigue cargando).
#   4. Los intentos fallidos del callback (redirige a /login?error=...) también cuentan.
#
# Las IP de los "clientes" se simulan con X-Forwarded-For (el borde confía en él solo desde redes
# privadas: la petición desde este equipo llega por el bridge de Docker). Sin dependencias: bash, curl, jq.
#   ./tests/security/seg1-bruteforce.sh            (con `docker compose up -d` activo)
set -uo pipefail
EDGE="${ZEAL_API:-http://localhost:8080}"
CS="${CROWDSEC_CONTAINER:-zeal-crowdsec}"
run="$(date +%s)"
ATTACKER="203.0.113.$((run % 200 + 20))"       # TEST-NET-3: no es una IP real
BYSTANDER="198.51.100.$((run % 200 + 20))"     # TEST-NET-2
FAILER="192.0.2.$((run % 200 + 20))"           # TEST-NET-1
fail=0; total=0
check() { total=$((total + 1)); if [ "$2" = true ]; then echo "OK   $1 ${3:-}"; else echo "FAIL $1 ${3:-}"; fail=$((fail + 1)); fi; }
post_login() { curl -s -o /dev/null -D - -X POST "$EDGE/api/auth/microsoft" -H "X-Forwarded-For: $1" \
  -H 'Content-Type: application/json' -d '{"remember":false,"returnTo":"/"}'; }

echo "Atacante $ATTACKER · otra persona $BYSTANDER · intentos fallidos $FAILER"

# 1. 100 intentos en menos de un minuto desde una IP
declare -A codes
last_headers=""
for i in $(seq 1 100); do
  headers="$(post_login "$ATTACKER")"
  code="$(head -1 <<<"$headers" | awk '{print $2}')"
  codes[$code]=$(( ${codes[$code]:-0} + 1 ))
  [ "$code" = 429 ] && last_headers="$headers"
done
echo "     respuestas del atacante: $(for c in "${!codes[@]}"; do printf '%s×%s ' "$c" "${codes[$c]}"; done)"
check "100 intentos: pasan solo los primeros y el resto recibe 429 (no 503)" "$([ "${codes[429]:-0}" -ge 40 ] && [ -z "${codes[503]:-}" ] && echo true || echo false)"
retry="$(grep -i '^retry-after:' <<<"$last_headers" | tr -d '\r' | awk '{print $2}')"
check "el 429 trae Retry-After con los segundos de espera" "$([ "${retry:-0}" -gt 0 ] && echo true || echo false)" "(Retry-After: ${retry:-—})"

# 2. Otra IP entra con normalidad
other="$(post_login "$BYSTANDER" | head -1 | awk '{print $2}')"
check "otra IP no se ve afectada" "$([ "$other" = 200 ] && echo true || echo false)" "(HTTP $other)"

# 3. CrowdSec lo registra y el borde bloquea /api/ a esa IP
decided=false
for i in $(seq 1 30); do
  if docker exec "$CS" cscli decisions list -o json 2>/dev/null | jq -e --arg ip "$ATTACKER" '[.[]?.decisions[]? | select(.value == $ip)] | length > 0' > /dev/null; then decided=true; break; fi
  sleep 2
done
check "CrowdSec registra la alerta y la decisión de bloqueo" "$decided" "($(docker exec "$CS" cscli alerts list -o json 2>/dev/null | jq -r --arg ip "$ATTACKER" '[.[]? | select(.source.value == $ip) | .scenario] | first // "sin alerta"'))"
blocked=false
for i in $(seq 1 15); do
  api="$(curl -s -D - -o /dev/null "$EDGE/api/proyectos" -H "X-Forwarded-For: $ATTACKER")"
  if [ "$(head -1 <<<"$api" | awk '{print $2}')" = 403 ]; then blocked=true; break; fi
  sleep 2
done
retry403="$(grep -i '^retry-after:' <<<"$api" | tr -d '\r' | awk '{print $2}')"
check "el borde responde 403 con Retry-After a la IP bloqueada en /api/" "$blocked" "(Retry-After: ${retry403:-—})"
spa="$(curl -s -o /dev/null -w '%{http_code}' "$EDGE/gateway/health" -H "X-Forwarded-For: $ATTACKER")"
check "el sitio (fuera de /api/) sigue respondiendo a esa IP" "$([ "$spa" = 200 ] && echo true || echo false)" "(HTTP $spa)"
okother="$(curl -s -o /dev/null -w '%{http_code}' "$EDGE/api/proyectos" -H "X-Forwarded-For: $BYSTANDER")"
check "otra IP sigue pasando (401 por no traer token, no 403)" "$([ "$okother" = 401 ] && echo true || echo false)" "(HTTP $okother)"

# 4. Intentos fallidos del callback (302 → /login?error=...), sin llegar al límite de NGINX
for i in $(seq 1 14); do
  curl -s -o /dev/null "$EDGE/api/auth/microsoft/callback?code=x&state=y" -H "X-Forwarded-For: $FAILER"; sleep 0.3
done
redirect="$(curl -s -o /dev/null -w '%{redirect_url}' "$EDGE/api/auth/microsoft/callback?code=x&state=y" -H "X-Forwarded-For: $BYSTANDER")"
check "un callback fallido redirige a /login?error=… (no es un 401)" "$([[ "$redirect" == *"/login?error="* ]] && echo true || echo false)" "($redirect)"
detected=false
for i in $(seq 1 30); do
  if docker exec "$CS" cscli decisions list -o json 2>/dev/null | jq -e --arg ip "$FAILER" '[.[]?.decisions[]? | select(.value == $ip)] | length > 0' > /dev/null; then detected=true; break; fi
  sleep 2
done
check "CrowdSec detecta los callbacks fallidos y bloquea esa IP" "$detected"

echo
echo "Decisiones activas:"; docker exec "$CS" cscli decisions list 2>/dev/null | sed 's/^/   /' | head -12
[ "$fail" -eq 0 ] && echo "RESULTADO: APROBADO ($total/$total)" || { echo "RESULTADO: FALLIDO ($fail de $total)"; exit 1; }
