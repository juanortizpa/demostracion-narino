#!/usr/bin/env bash
#
# run_controller.sh - Arranca el controlador Ryu (Fase 1).
#
# Ejecutar en la VM del controlador. Escucha OpenFlow 1.3 en el puerto 6653.
# Con la variable REST=1 tambien levanta la API REST (ofctl_rest) en :8080,
# que se usara a partir de la Fase 2 para inyectar flujos.
#
#     ./scripts/run_controller.sh           # solo learning switch
#     REST=1 ./scripts/run_controller.sh    # learning switch + API REST
#
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONTROLLER="${ROOT_DIR}/controller/simple_switch_13.py"

# Si ryu-manager no esta en el PATH, intenta activar el venv del instalador.
if ! command -v ryu-manager >/dev/null 2>&1; then
    for V in /root/ryu-venv "${HOME}/ryu-venv" /opt/ryu-venv; do
        if [[ -x "${V}/bin/ryu-manager" ]]; then
            # shellcheck disable=SC1091
            source "${V}/bin/activate"
            break
        fi
    done
fi

if ! command -v ryu-manager >/dev/null 2>&1; then
    echo "ryu-manager no encontrado. Ejecuta: sudo bash lab.sh instalar" >&2
    exit 1
fi

APPS=("${CONTROLLER}")
if [[ "${REST:-0}" == "1" ]]; then
    APPS+=("ryu.app.ofctl_rest")
    echo "==> API REST de Ryu habilitada en el puerto 8080"
fi

echo "==> Iniciando Ryu (OpenFlow 1.3, puerto 6653). Ctrl+C para detener."
exec ryu-manager --ofp-tcp-listen-port 6653 "${APPS[@]}"
