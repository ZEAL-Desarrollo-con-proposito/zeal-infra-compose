#!/usr/bin/env bash
# SEG-1 (HU-BE-20) sobre el despliegue REAL en Azure. El "atacante" es la VM B (su IP pública) que dispara
# intentos de login contra el borde de la máquina A; el "usuario normal" es ESTE equipo, que entra a la vez.
# Se comprueba: límite de tasa (429 + Retry-After), bloqueo de CrowdSec (403 solo en /api/), que otra IP entra
# con normalidad y que el ataque queda registrado. Al final se levanta el bloqueo de B.
#
#   SITE=zeal-xxxxxx.trafficmanager.net ./tests/security/seg1-azure.sh
#   Opcionales: RG (rg-zeal), VM_B (vm-zeal-b), A_PUB, B_PUB, ATTEMPTS (110), SLEEP (0.5)
set -euo pipefail
: "${SITE:?Define SITE (nombre de Traffic Manager)}"
RG="${RG:-rg-zeal}"; VM_A="${VM_A:-vm-zeal-a}"; VM_B="${VM_B:-vm-zeal-b}"
A_PUB="${A_PUB:-$(az network public-ip show -g "$RG" -n pip-zeal-a --query ipAddress -o tsv)}"
B_PUB="${B_PUB:-$(az network public-ip show -g "$RG" -n pip-zeal-b --query ipAddress -o tsv)}"
ATTEMPTS="${ATTEMPTS:-110}"; PAUSE="${SLEEP:-0.5}"
# Devuelve solo la salida estándar del comando (Azure la envuelve entre [stdout] y [stderr]).
run() { az vm run-command invoke -g "$RG" -n "$1" --command-id RunShellScript -o json --scripts "$2" \
  | jq -r '.value[0].message' | awk '/^\[stdout\]/{f=1; next} /^\[stderr\]/{f=0} f'; }
code() { curl -s --max-time 10 -o /dev/null -w '%{http_code}' --resolve "$SITE:443:$A_PUB" "$@"; }
login() { code -X POST "https://$SITE/api/auth/microsoft" -H 'Content-Type: application/json' -d '{"remember":false,"returnTo":"/"}'; }

echo "== SEG-1 · atacante: $VM_B ($B_PUB) → borde de A ($A_PUB) · usuario normal: este equipo"
echo "   antes del ataque, usuario normal: login=$(login)  api=$(code "https://$SITE/api/users/me")(401 sin token = responde)"
echo "   $(date +%T) disparando $ATTEMPTS intentos desde B (≈ $(echo "$ATTEMPTS * $PAUSE" | bc) s)…"
out="$(run "$VM_B" "for i in \$(seq 1 $ATTEMPTS); do curl -s -o /dev/null -D- --max-time 10 --resolve $SITE:443:$A_PUB -X POST https://$SITE/api/auth/microsoft -H 'Content-Type: application/json' -d '{\"remember\":false,\"returnTo\":\"/\"}' | awk 'NR==1{c=\$2} tolower(\$1)==\"retry-after:\"{r=\$2} END{print c, r}'; sleep $PAUSE; done")"
echo "$out" | grep -E '^[0-9]{3}' > "${TMPDIR:-/tmp}/seg1-azure.codes"
printf '   respuestas del atacante: '; awk '{c[$1]++} END{for(k in c) printf "%s×%s  ", k, c[k]; print ""}' "${TMPDIR:-/tmp}/seg1-azure.codes"
first429="$(grep -n '^429' "${TMPDIR:-/tmp}/seg1-azure.codes" | head -1 | cut -d: -f1 || true)"
first403="$(grep -n '^403' "${TMPDIR:-/tmp}/seg1-azure.codes" | head -1 | cut -d: -f1 || true)"
echo "   primer 429 en el intento ${first429:-—}; primer 403 (bloqueo de CrowdSec) en el intento ${first403:-—}"
echo "   Retry-After visto en el 429: $(grep '^429' "${TMPDIR:-/tmp}/seg1-azure.codes" | awk '{print $2}' | sort -u | tr '\n' ' ')"

echo "   durante el bloqueo, usuario normal (otra IP): login=$(login)  front=$(code "https://$SITE/")"
decisions="$(run "$VM_A" "docker exec zeal-app-crowdsec-1 cscli decisions list -o raw 2>/dev/null")"
echo "   CrowdSec en A bloquea a $B_PUB: $(echo "$decisions" | grep -q "$B_PUB" && echo sí || echo no)  ($(echo "$decisions" | grep "$B_PUB" | head -1 | cut -d, -f4,6,8 | cut -c1-70))"
echo "   alertas registradas en CrowdSec (escenario zeal-*): $(run "$VM_A" "docker exec zeal-app-crowdsec-1 cscli alerts list -o raw 2>/dev/null" | grep -c zeal || true)"
echo "   atacante bloqueado en /api/: $(run "$VM_B" "curl -s -o /dev/null -w '%{http_code}' --max-time 10 --resolve $SITE:443:$A_PUB -X POST https://$SITE/api/auth/microsoft -d '{}' -H 'Content-Type: application/json'")  ·  el front sigue: $(run "$VM_B" "curl -s -o /dev/null -w '%{http_code}' --max-time 10 --resolve $SITE:443:$A_PUB https://$SITE/")"

run "$VM_A" "docker exec zeal-app-crowdsec-1 cscli decisions delete --ip $B_PUB" > /dev/null
echo "   bloqueo de $B_PUB levantado"
ok=1
[ -n "$first429" ] || ok=0
[ -n "$first403" ] || ok=0
[ "$(login)" = 200 ] || ok=0
[ "$ok" -eq 1 ] && echo "RESULTADO SEG-1: APROBADO" || { echo "RESULTADO SEG-1: FALLIDO"; exit 1; }
