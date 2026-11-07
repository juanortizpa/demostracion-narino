#!/usr/bin/env bash
#
# config_host.sh - Direccionamiento IPv4 estatico para los hosts del laboratorio.
#
# Fase 1. Ejecutar como root en cada VM host (Ubuntu Server) dentro de GNS3:
#     sudo ./hosts/config_host.sh h1      # victima A
#     sudo ./hosts/config_host.sh h2      # victima B / servidor
#     sudo ./hosts/config_host.sh h3      # atacante (se usa en Fase 2)
#
# Asigna la IP correspondiente al rol sobre la interfaz de datos.
#
set -euo pipefail

# ---- Parametros (deben coincidir con docs/TOPOLOGIAS.md) ----
IFACE="${IFACE:-eth0}"     # interfaz de datos del host (ip link show)
PREFIX="24"
NET="10.0.0"

declare -A IPMAP=(
    ["h1"]="11"   # victima A
    ["h2"]="12"   # victima B / servidor
    ["h3"]="66"   # atacante
)

ROLE="${1:-}"
if [[ -z "${ROLE}" || -z "${IPMAP[$ROLE]:-}" ]]; then
    echo "Uso: sudo $0 {h1|h2|h3}   (interfaz por defecto: ${IFACE})" >&2
    echo "  h1 = victima A (10.0.0.11)" >&2
    echo "  h2 = victima B / servidor (10.0.0.12)" >&2
    echo "  h3 = atacante (10.0.0.66)" >&2
    exit 1
fi

if [[ "${EUID}" -ne 0 ]]; then
    echo "Ejecuta como root: sudo $0 ${ROLE}" >&2
    exit 1
fi

IP="${NET}.${IPMAP[$ROLE]}"

echo "==> Configurando ${ROLE} -> ${IP}/${PREFIX} en ${IFACE}"
ip addr flush dev "${IFACE}"
ip addr add "${IP}/${PREFIX}" dev "${IFACE}"
ip link set dev "${IFACE}" up

# Habilitar reenvio IPv4 solo en el atacante (necesario para el MITM de la Fase 2)
if [[ "${ROLE}" == "h3" ]]; then
    echo "==> (atacante) habilitando reenvio IPv4 para no romper la conectividad durante el MITM"
    sysctl -w net.ipv4.ip_forward=1
fi

echo "==> Direccion asignada:"
ip -4 addr show dev "${IFACE}" | grep inet
echo ""
echo "Prueba de conectividad sugerida:"
echo "    ping -c 3 ${NET}.12   # alcanzar a h2 desde h1"
