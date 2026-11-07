#!/usr/bin/env python3
"""
flow_stats.py - Extrae estadisticas de flujo del controlador Ryu via API REST (Fase 3).

Consulta periodicamente la API REST de Ryu y guarda los contadores de flujo en JSON
y en un log legible. Sirve para detectar anomalias estadisticas del MITM.

Uso:
    python3 scripts/flow_stats.py --controller 192.168.100.10 --interval 5 --duration 120
    python3 scripts/flow_stats.py --controller 192.168.100.10 --once   # una sola consulta
"""

import argparse
import json
import os
import sys
import time
from datetime import datetime

try:
    import requests
except ImportError:
    print("[!] Instala requests: pip3 install requests")
    sys.exit(1)

ROOT_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CAPTURES_DIR = os.path.join(ROOT_DIR, "captures")
os.makedirs(CAPTURES_DIR, exist_ok=True)


def get_switches(base_url):
    """Retorna lista de DPIDs registrados en Ryu."""
    try:
        r = requests.get(f"{base_url}/stats/switches", timeout=5)
        r.raise_for_status()
        return r.json()
    except Exception as e:
        print(f"[!] No se pudo contactar al controlador: {e}")
        return []


def get_flow_stats(base_url, dpid):
    """Retorna estadisticas de flujo de un switch."""
    try:
        r = requests.get(f"{base_url}/stats/flow/{dpid}", timeout=5)
        r.raise_for_status()
        return r.json().get(str(dpid), [])
    except Exception as e:
        print(f"[!] Error obteniendo flows del dpid {dpid}: {e}")
        return []


def get_port_stats(base_url, dpid):
    """Retorna estadisticas de puerto de un switch."""
    try:
        r = requests.get(f"{base_url}/stats/port/{dpid}", timeout=5)
        r.raise_for_status()
        return r.json().get(str(dpid), [])
    except Exception as e:
        print(f"[!] Error obteniendo ports del dpid {dpid}: {e}")
        return []


def analyze_flows(flows):
    """Analiza flujos buscando indicadores de compromiso."""
    ioc_hits = []

    for flow in flows:
        match = flow.get("match", {})
        actions = str(flow.get("actions", ""))
        priority = flow.get("priority", 0)
        cookie = flow.get("cookie", 0)
        pkt_count = flow.get("packet_count", 0)

        # IoC 1: Cookie de flujo malicioso (flow_inject.py usa 0x6d69746d)
        if cookie == 0x6d69746d:
            ioc_hits.append({
                "tipo": "FLUJO_MALICIOSO",
                "descripcion": "Cookie 0x6d69746d detectada (inyeccion de flujo MITM)",
                "flow": flow
            })

        # IoC 2: Flujo con OUTPUT a multiples puertos (duplicacion de trafico)
        if "OUTPUT" in actions and actions.count("OUTPUT") > 1:
            ioc_hits.append({
                "tipo": "DUPLICACION_TRAFICO",
                "descripcion": "Flujo redirige a multiples puertos (posible intercepcion)",
                "flow": flow
            })

        # IoC 3: Alta tasa de packet_in (controlador saturado = posible ARP flooding)
        if priority == 0 and pkt_count > 500:
            ioc_hits.append({
                "tipo": "ALTA_TASA_PACKET_IN",
                "descripcion": f"Flujo default con {pkt_count} paquetes — posible ARP flood",
                "flow": flow
            })

    return ioc_hits


def print_flow_summary(dpid, flows, ports):
    ts = datetime.now().strftime("%H:%M:%S")
    print(f"\n[{ts}] === DPID {dpid} ===")
    print(f"  Flujos activos : {len(flows)}")
    print(f"  Puertos        : {len(ports)}")

    for flow in flows:
        match = flow.get("match", {})
        actions = flow.get("actions", [])
        pkt = flow.get("packet_count", 0)
        byt = flow.get("byte_count", 0)
        pri = flow.get("priority", 0)
        cookie = flow.get("cookie", 0)
        cookie_flag = " [!MITM]" if cookie == 0x6d69746d else ""
        print(f"  Flow  pri={pri:4d}  pkts={pkt:6d}  bytes={byt:8d}"
              f"  match={match}  actions={actions}{cookie_flag}")

    for port in ports:
        pno = port.get("port_no", "?")
        rx = port.get("rx_packets", 0)
        tx = port.get("tx_packets", 0)
        err = port.get("rx_errors", 0) + port.get("tx_errors", 0)
        print(f"  Port {pno:3}  rx={rx:6d}  tx={tx:6d}  errors={err}")


def main():
    parser = argparse.ArgumentParser(description="Extrae estadisticas de flujo de Ryu (Fase 3)")
    parser.add_argument("--controller", default="192.168.100.10",
                        help="IP del controlador Ryu (default: 192.168.100.10)")
    parser.add_argument("--port", type=int, default=8080,
                        help="Puerto REST de Ryu (default: 8080)")
    parser.add_argument("--interval", type=float, default=5.0,
                        help="Intervalo de consulta en segundos (default: 5)")
    parser.add_argument("--duration", type=float, default=60.0,
                        help="Duracion total en segundos (default: 60)")
    parser.add_argument("--once", action="store_true",
                        help="Consultar una sola vez y salir")
    parser.add_argument("--output", default="",
                        help="Archivo JSON de salida (default: captures/flow_stats_<ts>.json)")
    args = parser.parse_args()

    base_url = f"http://{args.controller}:{args.port}"
    ts = datetime.now().strftime("%Y%m%d_%H%M%S")
    out_file = args.output or os.path.join(CAPTURES_DIR, f"flow_stats_{ts}.json")

    print(f"[*] Conectando a Ryu en {base_url}")
    switches = get_switches(base_url)
    if not switches:
        print("[!] No se encontraron switches. Verifica que Ryu este corriendo con --wsapi-port 8080")
        sys.exit(1)
    print(f"[+] Switches detectados: {switches}")

    all_records = []
    deadline = time.time() + (args.duration if not args.once else 0)
    all_ioc = []

    try:
        while True:
            record = {"timestamp": datetime.now().isoformat(), "switches": {}}
            for dpid in switches:
                flows = get_flow_stats(base_url, dpid)
                ports = get_port_stats(base_url, dpid)
                print_flow_summary(dpid, flows, ports)

                ioc = analyze_flows(flows)
                if ioc:
                    print(f"\n  [!!!] IoC DETECTADOS: {len(ioc)}")
                    for hit in ioc:
                        print(f"        - {hit['tipo']}: {hit['descripcion']}")
                    all_ioc.extend(ioc)

                record["switches"][str(dpid)] = {"flows": flows, "ports": ports, "ioc": ioc}

            all_records.append(record)

            if args.once or time.time() >= deadline:
                break
            time.sleep(args.interval)

    except KeyboardInterrupt:
        print("\n[*] Interrumpido por usuario.")

    # Guardar JSON
    output = {"metadata": {"controller": args.controller, "start": ts,
                           "total_records": len(all_records)},
              "ioc_summary": all_ioc,
              "records": all_records}
    with open(out_file, "w") as f:
        json.dump(output, f, indent=2)

    print(f"\n[+] Estadisticas guardadas en: {out_file}")
    print(f"[+] Total registros: {len(all_records)} | IoC detectados: {len(all_ioc)}")


if __name__ == "__main__":
    main()
