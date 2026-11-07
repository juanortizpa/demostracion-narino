#!/usr/bin/env bash
#
# verify_mitm.sh - Verificacion del ataque MITM (Fase 2).
#
# Comprueba, desde una VICTIMA, si el ataque ARP Spoofing tuvo exito: si la cache
# ARP de la victima asocia la IP del otro extremo con la MAC DEL ATACANTE, el MITM
# esta activo. Tambien resume los flujos del switch si se ejecuta en la VM de OVS.
#
# Uso (en una victima, p.ej. h1):
#     ./attack/verify_mitm.sh 10.0.0.12 02:00:00:00:00:66
#       arg1 = IP del otro extremo (h2)
#       arg2 = (opcional) MAC esperada del atacante; si coincide, MITM confirmado
#
set -euo pipefail

PEER_IP="${1:-10.0.0.12}"
ATTACKER_MAC="${2:-}"

echo "==> Tabla de vecinos ARP actual:"
ip neigh show || arp -n || true
echo ""

PEER_MAC="$(ip neigh show "${PEER_IP}" 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="lladdr") print $(i+1)}')"

if [[ -z "${PEER_MAC}" ]]; then
    echo "==> No hay entrada ARP para ${PEER_IP}. Genera trafico primero (ping ${PEER_IP})."
    exit 0
fi

echo "==> ${PEER_IP} esta asociado a la MAC: ${PEER_MAC}"

if [[ -n "${ATTACKER_MAC}" ]]; then
    if [[ "${PEER_MAC,,}" == "${ATTACKER_MAC,,}" ]]; then
        echo "==> [!!] MITM CONFIRMADO: ${PEER_IP} apunta a la MAC del atacante (${ATTACKER_MAC})."
        echo "        El trafico hacia ${PEER_IP} esta pasando por el atacante."
    else
        echo "==> MITM NO detectado: la MAC de ${PEER_IP} no es la del atacante."
    fi
else
    echo "==> Sugerencia: pasa la MAC del atacante como 2do argumento para confirmar el MITM."
    echo "    Tambien puedes comparar esta MAC contra la MAC real de ${PEER_IP}."
fi

echo ""
echo "==> (En la VM de OVS) revisa los flujos instalados:"
echo "    sudo ovs-ofctl -O OpenFlow13 dump-flows br0"
