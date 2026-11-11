#!/usr/bin/env bash
#
# setup_env.sh - Instala las dependencias del laboratorio segun el rol de la VM.
#
# Fase 1. Ejecutar como root en cada VM (Ubuntu Server 22.04):
#     sudo ./scripts/setup_env.sh controller   # VM con Ryu
#     sudo ./scripts/setup_env.sh ovs          # VM con Open vSwitch
#     sudo ./scripts/setup_env.sh host         # VMs host (incluye atacante)
#     sudo ./scripts/setup_env.sh all          # instala todo (PC de pruebas)
#
# Mejoras v2:
#   - Fuerza IPv4 en apt (evita "Connection refused" en NAT de VirtualBox).
#   - NO usa 'add-apt-repository' (la API de Launchpad suele fallar).
#     Agrega el PPA deadsnakes manualmente con llave en /etc/apt/keyrings.
#   - Reintentos automaticos ante errores transitorios de red.
#   - Idempotente: puede re-ejecutarse sin romper nada.
#   - Crea enlace ~/ryu-venv -> /root/ryu-venv para que lab.sh funcione.
#
set -euo pipefail

ROLE="${1:-all}"

if [[ "${EUID}" -ne 0 ]]; then
    echo "Ejecuta como root: sudo $0 ${ROLE}" >&2
    exit 1
fi

# -------------------------------------------------------------------------
# Opciones globales de apt: IPv4 + no interactivo + reintentos.
# -------------------------------------------------------------------------
export DEBIAN_FRONTEND=noninteractive
APT_OPTS=(
    -y
    -o Acquire::ForceIPv4=true
    -o Acquire::Retries=5
    -o Acquire::http::Timeout=30
    -o Acquire::https::Timeout=30
)

apt_update() {
    local n=0
    until apt-get "${APT_OPTS[@]}" update; do
        n=$((n+1))
        if (( n >= 3 )); then
            echo "[X] apt-get update fallo 3 veces." >&2
            return 1
        fi
        echo "[!] apt-get update fallo, reintento $n/3 en 5s..." >&2
        sleep 5
    done
}

apt_install() {
    local n=0
    until apt-get "${APT_OPTS[@]}" install "$@"; do
        n=$((n+1))
        if (( n >= 3 )); then
            echo "[X] apt-get install $* fallo 3 veces." >&2
            return 1
        fi
        echo "[!] apt-get install fallo, reintento $n/3 en 5s..." >&2
        sleep 5
    done
}

# -------------------------------------------------------------------------
# Forzar apt a usar IPv4 globalmente (por si otro script llama a apt sin
# pasar las opciones). Evita el "Connection refused" a Launchpad via IPv6.
# -------------------------------------------------------------------------
configurar_ipv4_apt() {
    local cfg=/etc/apt/apt.conf.d/99force-ipv4
    if [[ ! -f "${cfg}" ]]; then
        echo 'Acquire::ForceIPv4 "true";' > "${cfg}"
        echo "==> apt configurado para forzar IPv4 (${cfg})"
    fi
}

# -------------------------------------------------------------------------
# Deshabilita el repo del CDROM si quedo heredado de la instalacion.
# -------------------------------------------------------------------------
deshabilitar_cdrom() {
    if grep -qE '^deb cdrom:' /etc/apt/sources.list 2>/dev/null; then
        sed -i 's|^deb cdrom:|# deb cdrom:|' /etc/apt/sources.list
        echo "==> Repo CDROM comentado en /etc/apt/sources.list"
    fi
}

echo "==> Preparando apt (IPv4, sin CDROM, reintentos)"
configurar_ipv4_apt
deshabilitar_cdrom
apt_update

base_tools() {
    apt_install python3 python3-pip iproute2 iputils-ping tcpdump ca-certificates curl gnupg
}

# -------------------------------------------------------------------------
# Comprueba si el host del PPA deadsnakes es alcanzable. En muchas redes
# (universitarias, con proxy) ppa.launchpadcontent.net esta bloqueado y la
# conexion se rechaza (codigo 000). En ese caso compilamos Python 3.9.
# -------------------------------------------------------------------------
ppa_alcanzable() {
    local code
    code="$(curl -s --ipv4 --max-time 8 -o /dev/null -w '%{http_code}' \
            "https://ppa.launchpadcontent.net" 2>/dev/null || echo 000)"
    [[ "${code}" != "000" ]]
}

# -------------------------------------------------------------------------
# Agrega el PPA deadsnakes (Python 3.9 para Ubuntu 22.04) a MANO.
# Evita 'add-apt-repository' porque consulta la API de Launchpad y falla
# con ConnectionRefused en muchas redes.
# Devuelve 1 si el PPA no es alcanzable (y limpia el listfile heredado).
# -------------------------------------------------------------------------
agregar_ppa_deadsnakes() {
    local keyring=/etc/apt/keyrings/deadsnakes.gpg
    local listfile=/etc/apt/sources.list.d/deadsnakes.list
    local keyid=F23C5A6CF475977595C89F51BA6932366A755776
    local codename
    codename="$(. /etc/os-release && echo "${UBUNTU_CODENAME:-${VERSION_CODENAME:-jammy}}")"

    if ! ppa_alcanzable; then
        echo "[!] ppa.launchpadcontent.net no es alcanzable en esta red."
        # Quita el listfile si quedo de un intento previo, para que los
        # proximos 'apt-get update' no fallen por esa fuente inalcanzable.
        rm -f "${listfile}"
        return 1
    fi

    install -d -m 0755 /etc/apt/keyrings

    if [[ ! -s "${keyring}" ]]; then
        echo "==> Descargando llave GPG de deadsnakes por HTTPS (${keyid:0:16}...)"
        # Descargamos la llave armada por HTTPS con curl (evita dirmngr, que
        # necesita /root/.gnupg y conexion de demonio, y suele fallar en VMs).
        local tmp gnupg_home url
        tmp="$(mktemp)"
        gnupg_home="$(mktemp -d)"
        chmod 700 "${gnupg_home}"
        url="https://keyserver.ubuntu.com/pks/lookup?op=get&options=mr&search=0x${keyid}"
        local n=0
        until curl -fsSL --ipv4 -o "${tmp}" "${url}" && [[ -s "${tmp}" ]]; do
            n=$((n+1))
            if (( n >= 3 )); then
                echo "[X] No se pudo descargar la llave GPG de deadsnakes." >&2
                rm -rf "${tmp}" "${gnupg_home}"
                return 1
            fi
            echo "[!] Reintento ${n}/3 de la llave GPG en 5s..." >&2
            sleep 5
        done
        # dearmor usa un homedir temporal propio para no tocar /root/.gnupg.
        GNUPGHOME="${gnupg_home}" gpg --batch --dearmor < "${tmp}" > "${keyring}"
        rm -rf "${tmp}" "${gnupg_home}"
        chmod 0644 "${keyring}"
        echo "==> Llave GPG instalada en ${keyring}"
    fi

    local line="deb [signed-by=${keyring}] https://ppa.launchpadcontent.net/deadsnakes/ppa/ubuntu ${codename} main"
    if [[ ! -f "${listfile}" ]] || ! grep -qF "${line}" "${listfile}"; then
        echo "${line}" > "${listfile}"
        echo "==> PPA deadsnakes agregado (${listfile})"
    fi
    apt_update
}

# -------------------------------------------------------------------------
# Compila Python 3.9 desde el codigo fuente de python.org.
# Fallback cuando el PPA deadsnakes esta bloqueado. Instala como 'altinstall'
# en /usr/local/bin/python3.9 sin tocar el python3 del sistema.
# -------------------------------------------------------------------------
compilar_python39() {
    local pyver="3.9.21"
    local src="/usr/local/src/Python-${pyver}"
    local tgz="/usr/local/src/Python-${pyver}.tgz"

    if [[ -x /usr/local/bin/python3.9 ]]; then
        echo "==> Python 3.9 ya compilado: $(/usr/local/bin/python3.9 --version)"
        return 0
    fi

    echo "==> Instalando dependencias de compilacion de Python"
    apt_install build-essential zlib1g-dev libssl-dev libffi-dev libsqlite3-dev \
        libbz2-dev libreadline-dev libncurses-dev liblzma-dev tk-dev uuid-dev

    echo "==> Descargando Python ${pyver} de python.org"
    mkdir -p /usr/local/src
    local n=0
    until curl -fsSL --ipv4 -o "${tgz}" \
            "https://www.python.org/ftp/python/${pyver}/Python-${pyver}.tgz" \
            && [[ -s "${tgz}" ]]; do
        n=$((n+1))
        if (( n >= 3 )); then
            echo "[X] No se pudo descargar Python ${pyver} de python.org." >&2
            return 1
        fi
        echo "[!] Reintento ${n}/3 de la descarga en 5s..." >&2
        sleep 5
    done

    echo "==> Descomprimiendo y compilando Python ${pyver} (varios minutos)..."
    tar -xzf "${tgz}" -C /usr/local/src
    if ! ( cd "${src}" \
           && ./configure --prefix=/usr/local --with-ensurepip=install \
           && make -j"$(nproc)" \
           && make altinstall ); then
        echo "[X] Fallo la compilacion de Python 3.9." >&2
        return 1
    fi
    hash -r
    echo "==> Python 3.9 compilado: $(/usr/local/bin/python3.9 --version)"
}

# -------------------------------------------------------------------------
# Obtiene Python 3.9: primero intenta el PPA; si esta bloqueado, compila.
# -------------------------------------------------------------------------
instalar_python39() {
    if command -v python3.9 >/dev/null 2>&1; then
        echo "==> python3.9 ya disponible: $(command -v python3.9)"
        return 0
    fi
    echo "==> Buscando Python 3.9 (necesario para Ryu 4.34)"
    if agregar_ppa_deadsnakes && apt_install python3.9 python3.9-venv python3.9-dev; then
        echo "==> python3.9 instalado desde el PPA deadsnakes."
        return 0
    fi
    echo "==> PPA no disponible: se compila Python 3.9 desde fuente."
    compilar_python39
}

install_controller() {
    echo "==> [controller] Instalando Ryu 4.34 con Python 3.9"
    echo "    (Ryu 4.34 NO funciona con Python 3.10, el default de Ubuntu 22.04)"
    base_tools

    instalar_python39

    local PY39
    PY39="$(command -v python3.9 || echo /usr/local/bin/python3.9)"
    if [[ ! -x "${PY39}" ]]; then
        echo "[X] No se encontro python3.9 tras la instalacion." >&2
        return 1
    fi

    local VENV_PATH="/root/ryu-venv"
    if [[ ! -x "${VENV_PATH}/bin/python" ]]; then
        echo "==> Creando entorno virtual en ${VENV_PATH} (con ${PY39})"
        "${PY39}" -m venv "${VENV_PATH}"
    else
        echo "==> Entorno virtual ya existe en ${VENV_PATH}, lo reuso"
    fi

    # shellcheck disable=SC1091
    source "${VENV_PATH}/bin/activate"
    pip install --upgrade "pip<21" "setuptools==58.2.0" wheel
    pip install "eventlet==0.30.2" "ryu==4.34" requests
    echo "==> Verificando instalacion:"
    ryu-manager --version
    deactivate

    # Enlace para que lab.sh (que usa ~/ryu-venv) lo encuentre.
    local target_user="${SUDO_USER:-root}"
    local home_user
    home_user="$(getent passwd "${target_user}" | cut -d: -f6)"
    if [[ -n "${home_user}" && "${home_user}" != "/root" ]]; then
        if [[ ! -e "${home_user}/ryu-venv" ]]; then
            ln -s "${VENV_PATH}" "${home_user}/ryu-venv"
            chown -h "${target_user}:${target_user}" "${home_user}/ryu-venv" || true
            echo "==> Enlace ${home_user}/ryu-venv -> ${VENV_PATH} creado"
        fi
    fi

    echo ""
    echo "IMPORTANTE: el venv se activa solo desde lab.sh (opcion de 'ryu')."
    echo "Si lo necesitas a mano:   source ${VENV_PATH}/bin/activate"
    echo ""
}

install_ovs() {
    echo "==> [ovs] Instalando Open vSwitch"
    base_tools
    apt_install openvswitch-switch openvswitch-common
    systemctl enable --now openvswitch-switch 2>/dev/null \
        || service openvswitch-switch start 2>/dev/null \
        || true
}

install_host() {
    echo "==> [host] Instalando Scapy, utilidades de captura y dependencias del atacante"
    base_tools
    apt_install tshark netcat-openbsd
    # Dependencias para la interceptacion/modificacion de paquetes (VM atacante h3).
    # Se instalan en todos los hosts para que la VM base clonada sirva como h1, h2 o h3.
    apt_install build-essential python3-dev libnetfilter-queue-dev libnfnetlink-dev
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
echo "==> Comprobacion final:"
if [[ "${ROLE}" == "controller" || "${ROLE}" == "all" ]]; then
    VENV_BIN="/root/ryu-venv/bin"
    if "${VENV_BIN}/ryu-manager" --version 2>/dev/null; then
        echo "    ryu-manager: OK (en ${VENV_BIN})"
    else
        echo "    ryu-manager: FALLO - revisa la instalacion del venv"
    fi
fi
command -v ovs-vsctl >/dev/null 2>&1 && echo "    ovs-vsctl:   OK" || true
python3 -c "import scapy; print('    scapy:      ', scapy.__version__)" 2>/dev/null || true
python3 -c "import netfilterqueue; print('    nfqueue:     OK')" 2>/dev/null || true

echo "==> Listo (rol: ${ROLE})."
