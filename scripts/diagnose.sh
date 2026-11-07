#!/usr/bin/env bash
#
# diagnose.sh - Diagnostica el stack SDN del laboratorio en un solo comando.
#
# Ejecutar en CUALQUIER VM del laboratorio:
#     sudo ./scripts/diagnose.sh
#
# Reporta el estado de cada capa: Ryu, OVS, conexion controlador, flujos y
# conectividad IPv4 entre hosts. Util para depurar cuando los pings fallan.
#
set -uo pipefail

# ---- Parametros ----
BRIDGE="${BRIDGE:-br0}"
CONTROLLER_IP="${CONTROLLER_IP:-192.168.100.10}"
CONTROLLER_PORT="${CONTROLLER_PORT:-6653}"
HOST_H1="${HOST_H1:-10.0.0.11}"
HOST_H2="${HOST_H2:-10.0.0.12}"
VENV_PATH="/root/ryu-venv"

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

ok()   { echo -e "  ${GREEN}[OK]${NC}    $*"; }
fail() { echo -e "  ${RED}[FALLO]${NC} $*"; }
warn() { echo -e "  ${YELLOW}[AVISO]${NC} $*"; }
sep()  { echo ""; echo "── $* ──────────────────────────────────"; }

echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║       Diagnostico del laboratorio SDN (MITM)        ║"
echo "╚══════════════════════════════════════════════════════╝"
echo "  VM: $(hostname)   |   $(date)"

# ─── 1. Ryu ───────────────────────────────────────────────────────────────────
sep "1. Controlador Ryu"

RYU_PID=$(pgrep -f "ryu-manager" 2>/dev/null || true)
if [[ -n "${RYU_PID}" ]]; then
    ok "ryu-manager corriendo (PID ${RYU_PID})"
else
    fail "ryu-manager NO esta corriendo"
    echo "     Arranca con:"
    echo "       source ${VENV_PATH}/bin/activate"
    echo "       REST=1 ./scripts/run_controller.sh"
fi

# Verifica que el puerto OpenFlow este abierto
if ss -tlnp 2>/dev/null | grep -q ":${CONTROLLER_PORT}"; then
    ok "Puerto OpenFlow ${CONTROLLER_PORT} escuchando"
else
    warn "Puerto ${CONTROLLER_PORT} no detectado en esta VM (normal si eres un host/OVS)"
fi

# Verifica que el puerto REST este abierto (solo si Ryu esta vivo)
if [[ -n "${RYU_PID}" ]]; then
    if ss -tlnp 2>/dev/null | grep -q ":8080"; then
        ok "API REST Ryu en :8080 activa"
    else
        warn "API REST Ryu (:8080) no detectada — arranca con: REST=1 ./scripts/run_controller.sh"
    fi
fi

# Venv de Python 3.9
sep "2. Entorno virtual Python 3.9 (Ryu)"
if [[ -x "${VENV_PATH}/bin/ryu-manager" ]]; then
    RYU_VER=$("${VENV_PATH}/bin/ryu-manager" --version 2>&1 || true)
    ok "venv en ${VENV_PATH} — ${RYU_VER}"
else
    fail "venv no encontrado en ${VENV_PATH}"
    echo "     Ejecuta en la VM del controlador:"
    echo "       sudo ./scripts/setup_env.sh controller"
fi

# ─── 3. Open vSwitch ──────────────────────────────────────────────────────────
sep "3. Open vSwitch"

if ! command -v ovs-vsctl >/dev/null 2>&1; then
    warn "ovs-vsctl no encontrado — esta VM no es el nodo OVS (normal)"
else
    # Servicio activo
    if systemctl is-active --quiet openvswitch-switch 2>/dev/null \
       || service openvswitch-switch status >/dev/null 2>&1; then
        ok "Servicio openvswitch-switch activo"
    else
        fail "Servicio openvswitch-switch INACTIVO"
        echo "     Inicia con: sudo systemctl start openvswitch-switch"
    fi

    # Puente existe
    if ovs-vsctl br-exists "${BRIDGE}" 2>/dev/null; then
        ok "Puente ${BRIDGE} existe"
    else
        fail "Puente ${BRIDGE} NO existe"
        echo "     Ejecuta: sudo ./ovs/setup_ovs.sh"
    fi

    # Puertos del puente
    PORTS=$(ovs-vsctl list-ports "${BRIDGE}" 2>/dev/null | tr '\n' ' ')
    if [[ -n "${PORTS}" ]]; then
        ok "Puertos en ${BRIDGE}: ${PORTS}"
    else
        fail "El puente ${BRIDGE} no tiene puertos — no conmutara trafico"
        echo "     Revisa DATA_IFACES en ovs/setup_ovs.sh"
    fi

    # Conexion al controlador
    CTRL_STATUS=$(ovs-vsctl get-controller "${BRIDGE}" 2>/dev/null || echo "")
    if echo "${CTRL_STATUS}" | grep -q "tcp:${CONTROLLER_IP}:${CONTROLLER_PORT}"; then
        ok "Controlador apuntado: ${CTRL_STATUS}"
    else
        fail "Controlador no configurado correctamente: '${CTRL_STATUS}'"
    fi

    # is_connected
    CONNECTED=$(ovs-vsctl --columns=is_connected find controller 2>/dev/null | grep -c "true" || echo "0")
    if [[ "${CONNECTED}" -gt 0 ]]; then
        ok "OVS conectado a Ryu (is_connected: true)"
    else
        fail "OVS NO esta conectado al controlador Ryu"
        echo "     Posibles causas:"
        echo "       a) Ryu no esta corriendo en ${CONTROLLER_IP}:${CONTROLLER_PORT}"
        echo "       b) Red de control (192.168.100.0/24) no alcanzable"
        echo "       c) Firewall bloqueando el puerto ${CONTROLLER_PORT}"
        echo "     Verifica conectividad: ping ${CONTROLLER_IP}"
        echo "     En modo debug: sudo ovs-vsctl set-fail-mode ${BRIDGE} standalone"
    fi

    # fail-mode
    FMODE=$(ovs-vsctl get-fail-mode "${BRIDGE}" 2>/dev/null || echo "no configurado")
    if [[ "${FMODE}" == "secure" ]]; then
        warn "fail-mode: secure — sin controlador, el switch NO reenvia trafico"
    elif [[ "${FMODE}" == "standalone" ]]; then
        warn "fail-mode: standalone (modo DEBUG) — el switch reenvia aunque Ryu este caido"
    else
        warn "fail-mode: ${FMODE}"
    fi

    # Flujos OpenFlow
    sep "4. Flujos OpenFlow"
    FLOWS=$(sudo ovs-ofctl -O OpenFlow13 dump-flows "${BRIDGE}" 2>/dev/null | grep -v "^OFPST" || echo "")
    FLOW_COUNT=$(echo "${FLOWS}" | grep -c "cookie=" 2>/dev/null || echo "0")
    if [[ "${FLOW_COUNT}" -gt 1 ]]; then
        ok "${FLOW_COUNT} flujos instalados por Ryu"
    elif [[ "${FLOW_COUNT}" -eq 1 ]]; then
        warn "Solo 1 flujo (probablemente el table-miss). Ryu aun no ha aprendido MACs."
        echo "     Genera trafico entre hosts para poblar la tabla."
    else
        fail "Sin flujos OpenFlow — Ryu no ha enviado reglas al OVS"
    fi
fi

# ─── 5. Conectividad de red ───────────────────────────────────────────────────
sep "5. Conectividad IPv4 entre hosts"

if command -v ping >/dev/null 2>&1; then
    echo "  Probando ping a h1 (${HOST_H1})..."
    if ping -c 2 -W 2 "${HOST_H1}" >/dev/null 2>&1; then
        ok "Alcanza ${HOST_H1} (h1)"
    else
        fail "No alcanza ${HOST_H1} (h1)"
    fi

    echo "  Probando ping a h2 (${HOST_H2})..."
    if ping -c 2 -W 2 "${HOST_H2}" >/dev/null 2>&1; then
        ok "Alcanza ${HOST_H2} (h2)"
    else
        fail "No alcanza ${HOST_H2} (h2)"
    fi
else
    warn "ping no disponible en esta VM"
fi

# ─── Resumen de interfaces ────────────────────────────────────────────────────
sep "6. Interfaces de red de esta VM"
ip -4 addr show | grep -E "(^[0-9]+:|inet )" | sed 's/^/  /'

echo ""
echo "══════════════════════════════════════════════════════"
echo "  Diagnostico completado."
echo "  Para mas detalle ejecuta en la VM OVS:"
echo "    sudo ovs-vsctl show"
echo "    sudo ovs-ofctl -O OpenFlow13 dump-flows ${BRIDGE}"
echo "══════════════════════════════════════════════════════"
echo ""
