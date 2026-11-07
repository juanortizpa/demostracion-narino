#!/usr/bin/env bash
#
# collect_evidence.sh - Recoleccion de evidencias del ataque MITM (Fase 3).
#
# Ejecutar en la VM atacante (h3) mientras el ataque ARP Spoofing esta activo.
# Captura trafico en la interfaz MITM y genera logs estructurados.
#
# Uso:
#   sudo ./scripts/collect_evidence.sh [interfaz] [duracion_segundos]
#   sudo ./scripts/collect_evidence.sh enp0s3 120
#
set -euo pipefail

IFACE="${1:-enp0s3}"
DURATION="${2:-120}"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="${ROOT_DIR}/captures"
mkdir -p "${OUT_DIR}"

if [[ "${EUID}" -ne 0 ]]; then
    echo "[!] Requiere root: sudo $0 ${IFACE} ${DURATION}" >&2
    exit 1
fi

if ! command -v tcpdump >/dev/null 2>&1; then
    echo "[!] tcpdump no encontrado. Instala con: sudo apt-get install -y tcpdump" >&2
    exit 1
fi

TS="$(date +%Y%m%d_%H%M%S)"
PCAP_MITM="${OUT_DIR}/mitm_capture_${TS}.pcap"
LOG_ARP="${OUT_DIR}/arp_events_${TS}.log"
LOG_SUMMARY="${OUT_DIR}/evidence_summary_${TS}.txt"

echo "============================================================"
echo "  RECOLECCION DE EVIDENCIAS — Fase 3"
echo "============================================================"
echo "  Interfaz : ${IFACE}"
echo "  Duracion : ${DURATION}s"
echo "  PCAP     : ${PCAP_MITM}"
echo "  Log ARP  : ${LOG_ARP}"
echo "============================================================"
echo ""
echo "[*] Iniciando captura (${DURATION}s)..."
echo "[*] Genera trafico en h1 y h2 mientras captura: ping, curl, nc"
echo ""

# --- CAPTURA PCAP COMPLETA ---
tcpdump -i "${IFACE}" -G "${DURATION}" -W 1 -w "${PCAP_MITM}" &
TCPDUMP_PID=$!

# --- LOG ARP EN TIEMPO REAL ---
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Inicio de captura ARP" > "${LOG_ARP}"
tcpdump -i "${IFACE}" -n arp -l 2>/dev/null | while IFS= read -r line; do
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ${line}" >> "${LOG_ARP}"
done &
ARP_PID=$!

# Espera la duracion
sleep "${DURATION}"

# Detener procesos auxiliares
kill "${ARP_PID}" 2>/dev/null || true
wait "${TCPDUMP_PID}" 2>/dev/null || true

echo ""
echo "[+] Captura finalizada."

# --- RESUMEN ---
PACKET_COUNT=$(tcpdump -r "${PCAP_MITM}" 2>/dev/null | wc -l || echo "0")
ARP_COUNT=$(grep -c "ARP\|arp" "${LOG_ARP}" 2>/dev/null || echo "0")

{
    echo "============================================================"
    echo "  RESUMEN DE EVIDENCIAS — ${TS}"
    echo "============================================================"
    echo "  Interfaz capturada : ${IFACE}"
    echo "  Duracion           : ${DURATION}s"
    echo "  Total paquetes     : ${PACKET_COUNT}"
    echo "  Eventos ARP        : ${ARP_COUNT}"
    echo "  Archivo PCAP       : ${PCAP_MITM}"
    echo "  Log ARP            : ${LOG_ARP}"
    echo ""
    echo "  Tabla ARP actual (ip neigh):"
    ip neigh show 2>/dev/null || echo "  (no disponible)"
    echo ""
    echo "  Interfaces de red:"
    ip addr show "${IFACE}" 2>/dev/null || true
    echo "============================================================"
} | tee "${LOG_SUMMARY}"

echo ""
echo "[+] Evidencias guardadas en: ${OUT_DIR}"
echo "[+] Analiza el PCAP con:     python3 scripts/analyze_ioc.py ${PCAP_MITM}"
