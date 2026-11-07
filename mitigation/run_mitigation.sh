#!/usr/bin/env bash
#
# run_mitigation.sh - Inicia Ryu con el modulo de mitigacion activa (Fase 4).
#
# Reemplaza simple_switch_13 por arp_monitor (que incluye learning switch +
# deteccion de ARP Spoofing + bloqueo activo + API REST de mitigacion).
#
# Uso (en la VM ryu, como usuario normal):
#     bash mitigation/run_mitigation.sh
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "${SCRIPT_DIR}")"
VENV="${HOME}/ryu-venv"

if [[ ! -d "${VENV}" ]]; then
    echo "[!] Venv no encontrado en ${VENV}"
    echo "    Crea el venv con: python3.9 -m venv ~/ryu-venv"
    echo "    Luego instala: pip install eventlet==0.30.2 ryu==4.34 requests"
    exit 1
fi

source "${VENV}/bin/activate"

# Verificar que ryu-manager existe
if ! command -v ryu-manager >/dev/null 2>&1; then
    echo "[!] ryu-manager no encontrado en el venv"
    exit 1
fi

echo "============================================================"
echo "  RYU — Modo Mitigacion Activa (Fase 4)"
echo "  Modulo  : mitigation/arp_monitor.py"
echo "  REST API: http://0.0.0.0:8080"
echo "  Log     : captures/mitigation_events.log"
echo "============================================================"
echo ""
echo "  Endpoints de mitigacion:"
echo "    GET  /mitigation/stats        — metricas y eventos"
echo "    GET  /mitigation/trusted_arp  — tabla ARP de confianza"
echo "    GET  /mitigation/blocked      — MACs bloqueadas"
echo "    DEL  /mitigation/unblock/<mac>— desbloquear MAC"
echo "    GET  /stats/flow/1            — flujos OpenFlow (ofctl_rest)"
echo "============================================================"
echo ""

cd "${ROOT_DIR}"

ryu-manager \
    --wsapi-port 8080 \
    --observe-links \
    mitigation/arp_monitor.py \
    ryu.app.ofctl_rest
