#!/usr/bin/env bash
# Certificado AUTOFIRMADO para el listener TLS de coturn en desarrollo (DT-5). En el nodo de medios
# real se montan los certificados emitidos para su dominio (ver docs/cowork/CHECKLIST_COWORK.md).
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p certs
if [ -s certs/turn.crt ] && [ -s certs/turn.key ]; then
  echo "Ya existen coturn/certs/turn.crt y turn.key"; exit 0
fi
openssl req -x509 -newkey rsa:2048 -nodes -days 365 -subj "/CN=localhost" \
  -addext "subjectAltName=DNS:localhost,IP:127.0.0.1" \
  -keyout certs/turn.key -out certs/turn.crt 2>/dev/null
chmod 644 certs/turn.crt certs/turn.key   # coturn corre sin privilegios y debe poder leerlos
echo "Certificado de desarrollo creado en coturn/certs/"
