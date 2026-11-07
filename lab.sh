#!/usr/bin/env bash
#
# lab.sh - Orquestador unico del laboratorio MITM en SDN.
# =====================================================================
# Un solo archivo para TODO. Reemplaza la larga lista de pasos manuales
# del README por un menu interactivo.
#
# Flujo recomendado (5 VMs):
#   1) En la VM BASE (una sola vez, antes de clonar):   ./lab.sh instalar
#   2) Apagar y CLONAR la base 5 veces en VirtualBox (MACs nuevas).
#   3) En el host Windows: host-windows/crear-vms.ps1   (configura las redes).
#   4) En CADA VM encendida:                            ./lab.sh
#      -> elige el rol (1=ryu 2=ovs 3=h1 4=h2 5=h3) la primera vez.
#
# El rol queda guardado en ~/.lab_rol; las siguientes veces el menu
# arranca directo en las acciones de ese rol.
# =====================================================================
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE="${HOME}/.lab_rol"
VENV="${HOME}/ryu-venv"

# ---- Esquema de direcciones (coincide con docs/TOPOLOGIAS.md) --------
CTRL_NET="192.168.100"     # plano de control (OpenFlow)
DATA_NET="10.0.0"          # plano de datos (victimas/atacante)
RYU_IP="${CTRL_NET}.10"
OVS_CTRL_IP="${CTRL_NET}.20"
OVS_DATA_IP="${DATA_NET}.1"
declare -A HOST_IP=( ["h1"]="${DATA_NET}.11" ["h2"]="${DATA_NET}.12" ["h3"]="${DATA_NET}.66" )

C_OK="\033[1;32m"; C_WARN="\033[1;33m"; C_ERR="\033[1;31m"; C_HEAD="\033[1;36m"; C_0="\033[0m"
say()  { echo -e "${C_HEAD}==>${C_0} $*"; }
ok()   { echo -e "${C_OK}[OK]${C_0} $*"; }
warn() { echo -e "${C_WARN}[!]${C_0} $*"; }
err()  { echo -e "${C_ERR}[X]${C_0} $*" >&2; }

# ---- Deteccion de interfaces (robusta: enp0sX, ensX, ethX) -----------
detect_ifaces() {
    mapfile -t IFACES < <(ip -o link show | awk -F': ' '{print $2}' \
        | grep -vE '^(lo|br0|ovs-system|.*@.*)$')
}

# ---- Auto-reparar permisos (para que todo corra sin 'chmod' manual) ---
fix_perms() {
    chmod +x "${ROOT_DIR}/lab.sh" 2>/dev/null || true
    chmod +x "${ROOT_DIR}"/scripts/*.sh "${ROOT_DIR}"/ovs/*.sh \
             "${ROOT_DIR}"/hosts/*.sh "${ROOT_DIR}"/attack/*.sh \
             "${ROOT_DIR}"/mitigation/*.sh 2>/dev/null || true
    chmod +x "${ROOT_DIR}"/attack/*.py "${ROOT_DIR}"/scripts/*.py 2>/dev/null || true
}

# =====================================================================
#  INSTALACION  (una sola vez en la VM base)
# =====================================================================
instalar_todo() {
    say "Instalando TODAS las dependencias en esta VM base (controlador + ovs + host)."
    say "Hazlo una sola vez; luego apaga y clona esta VM 5 veces."
    echo ""
    sudo bash "${ROOT_DIR}/scripts/setup_env.sh" all
    echo ""
    ok "Instalacion completa."
    echo ""
    echo "  Siguiente paso:"
    echo "    1) sudo shutdown now   (apaga la VM)"
    echo "    2) En VirtualBox: clic derecho -> Clonar -> 5 veces"
    echo "       (nombres: ryu, ovs, h1, h2, h3; marca 'Generar nuevas MAC')"
    echo "    3) En el host Windows ejecuta: host-windows/crear-vms.ps1"
    echo "    4) En cada VM: ./lab.sh  y elige su rol"
}

# =====================================================================
#  CONFIGURACION DE ROL  (IP persistente + servicio)
# =====================================================================
pedir_rol() {
    echo ""
    echo "  Selecciona el rol de ESTA maquina:"
    echo "    1) ryu  - controlador SDN            (${RYU_IP})"
    echo "    2) ovs  - switch OpenFlow            (${OVS_CTRL_IP} / ${OVS_DATA_IP})"
    echo "    3) h1   - victima A                  (${HOST_IP[h1]})"
    echo "    4) h2   - victima B / servidor       (${HOST_IP[h2]})"
    echo "    5) h3   - atacante                   (${HOST_IP[h3]})"
    echo ""
    read -rp "  Numero de rol [1-5]: " n
    case "$n" in
        1) ROL="ryu" ;; 2) ROL="ovs" ;; 3) ROL="h1" ;; 4) ROL="h2" ;; 5) ROL="h3" ;;
        *) err "Opcion invalida."; exit 1 ;;
    esac
    echo "${ROL}" > "${STATE}"
    ok "Rol guardado: ${ROL}  (archivo ${STATE})"
    configurar_ip
}

# Escribe un netplan persistente segun el rol y lo aplica (usa sudo).
configurar_ip() {
    detect_ifaces
    if [[ ${#IFACES[@]} -eq 0 ]]; then err "No se detectaron interfaces de red."; exit 1; fi
    local IF1="${IFACES[0]}"
    local IF2="${IFACES[1]:-}"
    local PLAN="/etc/netplan/90-lab-mitm.yaml"

    say "Interfaz principal detectada: ${IF1} ${IF2:+(segunda: ${IF2})}"

    local YAML
    case "${ROL}" in
        ryu)
            YAML="network:
  version: 2
  ethernets:
    ${IF1}:
      dhcp4: false
      addresses: [${RYU_IP}/24]"
            ;;
        ovs)
            if [[ -z "${IF2}" ]]; then
                err "La VM 'ovs' necesita 2 adaptadores de red. Apagala y agrega el Adaptador 2 (Red interna 'intnet')."
                exit 1
            fi
            YAML="network:
  version: 2
  ethernets:
    ${IF1}:
      dhcp4: false
      addresses: [${OVS_CTRL_IP}/24]
    ${IF2}:
      dhcp4: false"
            ;;
        h1|h2|h3)
            YAML="network:
  version: 2
  ethernets:
    ${IF1}:
      dhcp4: false
      addresses: [${HOST_IP[$ROL]}/24]"
            ;;
    esac
    echo "${YAML}" | sudo tee "${PLAN}" >/dev/null
    sudo chmod 600 "${PLAN}"
    sudo netplan apply
    ok "IP persistente aplicada (${PLAN})."

    if [[ "${ROL}" == "h3" ]]; then
        sudo sysctl -w net.ipv4.ip_forward=1 >/dev/null
        echo "net.ipv4.ip_forward=1" | sudo tee /etc/sysctl.d/99-lab-forward.conf >/dev/null
        ok "Reenvio IPv4 activado de forma persistente (necesario para el MITM)."
    fi
    echo ""
    ip -4 addr show dev "${IF1}" | grep -E 'inet ' || true
}

# =====================================================================
#  ACCIONES POR ROL
# =====================================================================
accion_ryu() {
    echo ""
    echo "  VM ryu - Controlador SDN"
    echo "    1) Iniciar controlador NORMAL          (demo del ataque)"
    echo "    2) Iniciar controlador con MITIGACION  (demo de la defensa)"
    echo "    3) Reconfigurar IP"
    echo "    0) Salir"
    read -rp "  Opcion: " o
    case "$o" in
        1) say "Arrancando Ryu (OpenFlow 1.3 + API REST). Ctrl+C para detener."
           source "${VENV}/bin/activate"; REST=1 bash "${ROOT_DIR}/scripts/run_controller.sh" ;;
        2) say "Arrancando Ryu en modo MITIGACION (detecta y bloquea ARP Spoofing)."
           bash "${ROOT_DIR}/mitigation/run_mitigation.sh" ;;
        3) configurar_ip ;;
        0) exit 0 ;;
        *) warn "Opcion invalida." ;;
    esac
}

accion_ovs() {
    echo ""
    echo "  VM ovs - Switch OpenFlow"
    echo "    1) Configurar/conectar el switch al controlador"
    echo "    2) Ver estado del switch (ovs-vsctl show)"
    echo "    3) Ver flujos instalados (dump-flows)"
    echo "    4) Reconfigurar IP"
    echo "    0) Salir"
    read -rp "  Opcion: " o
    case "$o" in
        1) detect_ifaces
           say "Configurando br0 con la interfaz de datos y apuntando a Ryu (${RYU_IP})."
           # setup_ovs.sh autodetecta la interfaz de datos (excluye la de control y br0)
           sudo env CONTROLLER_IP="${RYU_IP}" CONTROL_IFACE="${IFACES[0]}" \
               bash "${ROOT_DIR}/ovs/setup_ovs.sh"
           sudo ip addr add "${OVS_DATA_IP}/24" dev br0 2>/dev/null || true
           sudo ip link set br0 up || true
           ok "Switch configurado. IP de datos ${OVS_DATA_IP} en br0." ;;
        2) sudo ovs-vsctl show ;;
        3) sudo ovs-ofctl -O OpenFlow13 dump-flows br0 ;;
        4) configurar_ip ;;
        0) exit 0 ;;
        *) warn "Opcion invalida." ;;
    esac
}

accion_victima() {
    local yo="$1"
    local peer; [[ "$yo" == "h1" ]] && peer="${HOST_IP[h2]}" || peer="${HOST_IP[h1]}"
    echo ""
    echo "  VM ${yo} - Victima"
    echo "    1) Enviar un MENSAJE al otro equipo (chat en vivo)   -> ${peer}"
    echo "    2) Recibir mensajes (abrir buzon)                    [deja esto abierto]"
    echo "    3) Generar trafico de prueba (ICMP/HTTP/TCP)         -> ${peer}"
    echo "    4) Verificar si me estan interceptando (tabla ARP)"
    echo "    5) Reconfigurar IP"
    echo "    0) Salir"
    read -rp "  Opcion: " o
    case "$o" in
        1) say "Escribe tu mensaje y pulsa Enter. El otro equipo (o el atacante) lo recibira."
           echo "    (Ctrl+C para terminar)"
           nc "${peer}" 9000 ;;
        2) say "Buzon abierto en el puerto 9000. Los mensajes entrantes apareceran aqui:"
           echo "    (Ctrl+C para cerrar)"
           while true; do nc -l -p 9000; echo "    --- (conexion cerrada, esperando otra) ---"; done ;;
        3) bash "${ROOT_DIR}/attack/demo_traffic.sh" "${peer}" ;;
        4) bash "${ROOT_DIR}/attack/verify_mitm.sh" "${peer}" ;;
        5) configurar_ip ;;
        0) exit 0 ;;
        *) warn "Opcion invalida." ;;
    esac
}

# Arranca el ARP spoofing en segundo plano (si no esta ya activo).
arp_activo()   { pgrep -f 'attack/arp_spoof.py' >/dev/null 2>&1; }
start_arp_bg() {
    if arp_activo; then ok "ARP spoofing ya estaba activo."; return; fi
    say "Poniendome en medio de h1<->h2 (ARP spoofing en segundo plano)..."
    sudo sh -c "python3 '${ROOT_DIR}/attack/arp_spoof.py' \
        --target '${HOST_IP[h1]}' --gateway '${HOST_IP[h2]}' \
        >/tmp/lab_arpspoof.log 2>&1 &"
    sleep 3
    if arp_activo; then ok "ARP spoofing activo (log: /tmp/lab_arpspoof.log)."
    else err "No se pudo iniciar el ARP spoofing. Revisa /tmp/lab_arpspoof.log"; fi
}
stop_arp_bg() {
    if arp_activo; then
        say "Deteniendo el ataque y restaurando las caches ARP..."
        sudo pkill -INT -f 'attack/arp_spoof.py' 2>/dev/null || true
        sleep 2
        ok "Ataque detenido. La red vuelve a la normalidad."
    fi
}

accion_atacante() {
    echo ""
    echo "  VM h3 - Atacante  (todo en un paso: el ARP spoofing se activa solo)"
    echo "    1) ATACAR y solo VER el trafico (interceptar)"
    echo "    2) ATACAR y ALTERAR el mensaje al vuelo"
    echo "    3) DETENER el ataque (restaurar la red)"
    echo "    4) [avanzado] Solo envenenar ARP (sin interceptar)"
    echo "    5) Reconfigurar IP"
    echo "    0) Salir"
    read -rp "  Opcion: " o
    case "$o" in
        1) start_arp_bg
           say "Interceptando y mostrando el trafico (solo lectura). Ctrl+C para volver al menu."
           sudo python3 "${ROOT_DIR}/attack/mitm_intercept.py" --mode sniff --auto-iptables || true
           stop_arp_bg ;;
        2) start_arp_bg
           read -rp "  Palabra a buscar en el mensaje: " f
           read -rp "  Reemplazar por: " r
           say "Alterando '${f}' -> '${r}' en el trafico que pasa por mi. Ctrl+C para volver al menu."
           sudo python3 "${ROOT_DIR}/attack/mitm_intercept.py" --mode modify \
               --find "${f}" --replace "${r}" --auto-iptables || true
           stop_arp_bg ;;
        3) if arp_activo; then stop_arp_bg; else ok "No habia ningun ataque activo."; fi ;;
        4) say "Envenenando ARP entre ${HOST_IP[h1]} y ${HOST_IP[h2]}. Ctrl+C restaura."
           sudo python3 "${ROOT_DIR}/attack/arp_spoof.py" \
               --target "${HOST_IP[h1]}" --gateway "${HOST_IP[h2]}" ;;
        5) configurar_ip ;;
        0) exit 0 ;;
        *) warn "Opcion invalida." ;;
    esac
}

# =====================================================================
#  MENU PRINCIPAL
# =====================================================================
main() {
    fix_perms
    case "${1:-menu}" in
        instalar|install) instalar_todo; exit 0 ;;
        rol|role)         pedir_rol; exit 0 ;;
        ip)               ROL="$(cat "${STATE}" 2>/dev/null || true)"
                          if [[ -z "${ROL}" ]]; then pedir_rol; else configurar_ip; fi
                          exit 0 ;;
    esac

    echo -e "${C_HEAD}"
    echo "  =============================================="
    echo "   LABORATORIO MITM en SDN  -  menu del lab"
    echo "  =============================================="
    echo -e "${C_0}"

    if [[ ! -f "${STATE}" ]]; then
        warn "Esta VM todavia no tiene rol asignado."
        pedir_rol
    fi
    ROL="$(cat "${STATE}")"
    echo "  Rol de esta maquina: ${ROL}"

    case "${ROL}" in
        ryu)   accion_ryu ;;
        ovs)   accion_ovs ;;
        h1|h2) accion_victima "${ROL}" ;;
        h3)    accion_atacante ;;
        *)     err "Rol desconocido en ${STATE}. Borra ese archivo y vuelve a correr ./lab.sh"; exit 1 ;;
    esac
}

main "$@"
