#!/usr/bin/env bash
#
# setup_ovs.sh - Configura Open vSwitch en su VM y lo conecta al controlador Ryu.
#
# Fase 1. Ejecutar como root en la VM de Open vSwitch dentro de GNS3:
#     sudo ./ovs/setup_ovs.sh
#
# Variables de entorno opcionales:
#   CONTROLLER_IP    IP de la VM Ryu (default: 192.168.100.10)
#   CONTROLLER_PORT  Puerto OpenFlow (default: 6653)
#   CONTROL_IFACE    Interfaz hacia Ryu, excluida del bridge (default: eth0)
#   DATA_IFACES      Array de interfaces de datos; si no se define se autodetectan
#
# Ejemplos:
#   sudo ./ovs/setup_ovs.sh
#   CONTROLLER_IP=192.168.100.10 CONTROL_IFACE=ens3 sudo ./ovs/setup_ovs.sh
#   DATA_IFACES=("ens4" "ens5" "ens6") sudo ./ovs/setup_ovs.sh
#
set -euo pipefail

BRIDGE="br0"
CONTROLLER_IP="${CONTROLLER_IP:-192.168.100.10}"
CONTROLLER_PORT="${CONTROLLER_PORT:-6653}"
CONTROL_IFACE="${CONTROL_IFACE:-eth0}"

if [[ "${EUID}" -ne 0 ]]; then
    echo "Ejecuta como root: sudo $0" >&2
    exit 1
fi

if ! command -v ovs-vsctl >/dev/null 2>&1; then
    echo "Open vSwitch no encontrado. Ejecuta primero: sudo ./scripts/setup_env.sh ovs" >&2
    exit 1
fi

echo "==> Asegurando que el servicio de Open vSwitch este activo"
systemctl enable --now openvswitch-switch 2>/dev/null || service openvswitch-switch start || true

echo ""
echo "==> Interfaces de red disponibles en esta VM:"
ip -o link show | awk -F': ' '{print "    "$2}' | grep -v '^    lo$'
echo ""

# Auto-deteccion si no se definieron manualmente
if [[ -z "${DATA_IFACES[*]+x}" ]]; then
    mapfile -t ALL_IFACES < <(ip -o link show | awk -F': ' '{print $2}' | grep -v '^lo$')
    DATA_IFACES=()
    for ifc in "${ALL_IFACES[@]}"; do
        if [[ "${ifc}" == "${CONTROL_IFACE}" ]] \
            || [[ "${ifc}" == "${BRIDGE}" ]] \
            || [[ "${ifc}" == "ovs-system" ]]; then
            continue
        fi
        DATA_IFACES+=("${ifc}")
    done
    echo "==> Interfaces de datos autodetectadas: ${DATA_IFACES[*]:-NINGUNA}"
    echo "    (excluidas: lo, ${CONTROL_IFACE}, ${BRIDGE}, ovs-system)"
    echo "    Para forzar otras: DATA_IFACES=(\"eth1\" \"eth2\") sudo $0"
else
    echo "==> Interfaces de datos definidas manualmente: ${DATA_IFACES[*]}"
fi

if [[ ${#DATA_IFACES[@]} -eq 0 ]]; then
    echo "ERROR: No se encontraron interfaces de datos." >&2
    echo "Verifica con 'ip link show' y especifica manualmente:" >&2
    echo "    DATA_IFACES=(\"eth1\" \"eth2\") sudo $0" >&2
    exit 1
fi

echo ""
echo "==> Creando el puente ${BRIDGE} (si no existe)"
ovs-vsctl --may-exist add-br "${BRIDGE}"

echo "==> Forzando OpenFlow 1.3 en ${BRIDGE}"
ovs-vsctl set bridge "${BRIDGE}" protocols=OpenFlow13

echo "==> Agregando interfaces de datos como puertos del puente"
PORTS_ADDED=0
for ifc in "${DATA_IFACES[@]}"; do
    if ip link show "${ifc}" >/dev/null 2>&1; then
        ovs-vsctl --may-exist add-port "${BRIDGE}" "${ifc}"
        ip link set dev "${ifc}" up
        echo "    + ${ifc}"
        (( PORTS_ADDED++ )) || true
    else
        echo "    ! ${ifc} no existe en esta VM, se omite"
    fi
done

if [[ ${PORTS_ADDED} -eq 0 ]]; then
    echo "ERROR: Ningun puerto fue agregado al puente ${BRIDGE}." >&2
    echo "El OVS no podra conmutar trafico. Revisa los nombres de interfaz." >&2
    exit 1
fi

echo "==> Apuntando el controlador a tcp:${CONTROLLER_IP}:${CONTROLLER_PORT}"
ovs-vsctl set-controller "${BRIDGE}" "tcp:${CONTROLLER_IP}:${CONTROLLER_PORT}"
ovs-vsctl set-fail-mode "${BRIDGE}" secure

echo ""
echo "==> Estado actual del OVS:"
ovs-vsctl show

echo ""
echo "NOTA: fail-mode SECURE activo — los pings fallan hasta que Ryu este conectado."
echo ""
echo "Para debug sin controlador (trafico pasa igual):"
echo "    sudo ovs-vsctl set-fail-mode ${BRIDGE} standalone"
echo "Restaurar modo produccion:"
echo "    sudo ovs-vsctl set-fail-mode ${BRIDGE} secure"
echo ""
echo "Verificar conexion con el controlador:"
echo "    ovs-vsctl get-controller ${BRIDGE}"
echo "    ovs-ofctl -O OpenFlow13 dump-flows ${BRIDGE}"
