#!/usr/bin/env bash
#
# setup_env.sh - Instala las dependencias del laboratorio segun el rol de la VM.
#
# Fase 1. Ejecutar como root en cada VM (Ubuntu Server 22.04) dentro de GNS3:
#     sudo ./scripts/setup_env.sh controller   # VM con Ryu
#     sudo ./scripts/setup_env.sh ovs          # VM con Open vSwitch
#     sudo ./scripts/setup_env.sh host         # VMs host (incluye atacante)
#     sudo ./scripts/setup_env.sh all          # instala todo (PC de pruebas)
#
set -euo pipefail

ROLE="${1:-all}"

if [[ "${EUID}" -ne 0 ]]; then
    echo "Ejecuta como root: sudo $0 ${ROLE}" >&2
    exit 1
fi

echo "==> Actualizando indices de paquetes"
apt-get update

base_tools() {
    apt-get install -y python3 python3-pip iproute2 iputils-ping tcpdump
}

install_controller() {
    echo "==> [controller] Instalando Ryu 4.34 con Python 3.9"
    echo "    (Ryu 4.34 NO funciona con Python 3.10, el default de Ubuntu 22.04)"
    base_tools

    # Python 3.9 via deadsnakes PPA
    apt-get install -y software-properties-common
    add-apt-repository -y ppa:deadsnakes/ppa
    apt-get update
    apt-get install -y python3.9 python3.9-venv python3.9-dev

    local VENV_PATH="/root/ryu-venv"
    echo "==> Creando entorno virtual en ${VENV_PATH}"
    python3.9 -m venv "${VENV_PATH}"
    # shellcheck disable=SC1091
    source "${VENV_PATH}/bin/activate"

    pip install --upgrade "pip<21" "setuptools==58.2.0" wheel
    pip install "eventlet==0.30.2" "ryu==4.34" requests

    echo "==> Verificando instalacion:"
    ryu-manager --version

    deactivate

    echo ""
    echo "IMPORTANTE: activa el venv antes de arrancar Ryu en cada sesion:"
    echo "    source ${VENV_PATH}/bin/activate"
    echo "    REST=1 ./scripts/run_controller.sh"
    echo ""
}

install_ovs() {
    echo "==> [ovs] Instalando Open vSwitch"
    base_tools
    apt-get install -y openvswitch-switch openvswitch-common
    systemctl enable --now openvswitch-switch || service openvswitch-switch start || true
}

install_host() {
    echo "==> [host] Instalando Scapy, utilidades de captura y dependencias del atacante"
    base_tools
    apt-get install -y tshark curl netcat-openbsd
    # Dependencias para la interceptacion/modificacion de paquetes (VM atacante h3).
    # Se instalan en todos los hosts para que la VM base clonada sirva como h1, h2 o h3.
    apt-get install -y build-essential python3-dev libnetfilter-queue-dev libnfnetlink-dev
    pip3 install --upgrade pip
    pip3 install "scapy>=2.5.0" "netfilterqueue>=1.0.0" requests
}

case "${ROLE}" in
    controller) install_controller ;;
    ovs)        install_ovs ;;
    host)       install_host ;;
    all)        install_controller; install_ovs; install_host ;;
    *) echo "Rol invalido: ${ROLE} (usa: controller|ovs|host|all)" >&2; exit 1 ;;
esac

echo ""
echo "==> Comprobacion:"
if [[ "${ROLE}" == "controller" || "${ROLE}" == "all" ]]; then
    VENV_BIN="/root/ryu-venv/bin"
    if "${VENV_BIN}/ryu-manager" --version 2>/dev/null; then
        echo "    ryu-manager: OK (en ${VENV_BIN})"
    else
        echo "    ryu-manager: FALLO — revisa la instalacion del venv"
    fi
fi
command -v ovs-vsctl >/dev/null 2>&1 && echo "    ovs-vsctl: OK" || true
python3 -c "import scapy; print('    scapy:', scapy.__version__)" 2>/dev/null || true

echo "==> Listo (rol: ${ROLE})."
