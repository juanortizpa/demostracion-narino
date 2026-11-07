#!/usr/bin/env bash
#
# demo_traffic.sh - Genera trafico legitimo de prueba entre victimas (Fase 2).
#
# Se ejecuta en una VICTIMA (p.ej. h1) para producir trafico ICMP, TCP y HTTP
# hacia la otra victima/servidor (h2), de modo que el atacante pueda interceptarlo
# y/o modificarlo. Sirve para demostrar y validar el MITM.
#
# Uso (en h1):
#     ./attack/demo_traffic.sh 10.0.0.12
#
set -euo pipefail

PEER="${1:-10.0.0.12}"

echo "==> [demo] ICMP: ping a ${PEER}"
ping -c 4 "${PEER}" || true

echo ""
echo "==> [demo] TCP/HTTP: solicitud HTTP a ${PEER}:8000"
echo "    (en la otra VM levanta un servidor con: python3 -m http.server 8000)"
if command -v curl >/dev/null 2>&1; then
    curl -s --max-time 5 "http://${PEER}:8000/" | head -5 || echo "    (sin servidor HTTP en ${PEER}:8000)"
else
    echo "    curl no disponible; instala con: sudo apt-get install -y curl"
fi

echo ""
echo "==> [demo] TCP crudo: mensaje a ${PEER}:9000 (escucha con: nc -l -p 9000)"
if command -v nc >/dev/null 2>&1; then
    echo "Hola desde h1 - mensaje de prueba MITM" | timeout 5 nc "${PEER}" 9000 || \
        echo "    (sin listener netcat en ${PEER}:9000)"
else
    echo "    netcat no disponible; instala con: sudo apt-get install -y netcat"
fi

echo ""
echo "==> [demo] Trafico generado. Revisa la salida del atacante (mitm_intercept.py)."
