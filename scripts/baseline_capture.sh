#!/usr/bin/env bash
#
# baseline_capture.sh - Captura la linea base de trafico legitimo (Fase 1).
#
# Genera un .pcap de referencia ANTES de cualquier ataque, para poder comparar
# despues (Fase 3) el trafico normal contra el trafico bajo MITM.
#
# Uso (como root, en un host o en la VM de OVS):
#     sudo ./scripts/baseline_capture.sh <interfaz> [segundos]
# Ejemplo:
#     sudo ./scripts/baseline_capture.sh eth0 60
#
set -euo pipefail

IFACE="${1:-eth0}"
DURATION="${2:-60}"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="${ROOT_DIR}/captures"
mkdir -p "${OUT_DIR}"

if [[ "${EUID}" -ne 0 ]]; then
    echo "La captura requiere root: sudo $0 ${IFACE} ${DURATION}" >&2
    exit 1
fi

if ! command -v tcpdump >/dev/null 2>&1; then
    echo "tcpdump no encontrado. Ejecuta: sudo ./scripts/setup_env.sh host" >&2
    exit 1
fi

TS="$(date +%Y%m%d_%H%M%S)"
OUT="${OUT_DIR}/baseline_${IFACE}_${TS}.pcap"

echo "==> Capturando linea base en ${IFACE} durante ${DURATION}s"
echo "    Archivo: ${OUT}"
echo "    (Genera trafico legitimo en paralelo: ping, curl, ssh, etc.)"

# -G + -W 1 hace que tcpdump se detenga tras DURATION segundos
tcpdump -i "${IFACE}" -G "${DURATION}" -W 1 -w "${OUT}"

echo ""
echo "==> Captura finalizada. Resumen:"
tcpdump -r "${OUT}" 2>/dev/null | wc -l | xargs echo "    paquetes capturados:"
echo "    Abre el archivo en Wireshark para analizar la linea base."
