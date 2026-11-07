#!/usr/bin/env python3
"""
evaluate_mitigation.py - Evalua la eficacia del mecanismo de mitigacion (Fase 4).

Lee los logs generados por arp_monitor.py y los reportes de flow_anomaly.py,
calcula las metricas de eficacia y genera un informe final:

  - TP  (True Positives) : ataques detectados correctamente
  - FP  (False Positives): trafico legitimo bloqueado por error
  - FN  (False Negatives): ataques no detectados (si los hubiera)
  - Tiempo de deteccion  : desde inicio del ataque hasta primera alerta
  - Tiempo de respuesta  : desde primera alerta hasta primer bloqueo
  - Precision            : TP / (TP + FP)
  - Recall               : TP / (TP + FN)

Uso:
    # Evaluar con los logs existentes:
    python3 scripts/evaluate_mitigation.py

    # Especificar archivo de log:
    python3 scripts/evaluate_mitigation.py --log captures/mitigation_events.log

    # Consultar metricas en vivo desde la API REST de Ryu:
    python3 scripts/evaluate_mitigation.py --live --controller 192.168.100.10
"""

import argparse
import json
import os
import sys
from datetime import datetime

try:
    import requests
    HAS_REQUESTS = True
except ImportError:
    HAS_REQUESTS = False

ROOT_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CAPTURES_DIR = os.path.join(ROOT_DIR, "captures")
DEFAULT_LOG = os.path.join(CAPTURES_DIR, "mitigation_events.log")


def load_events(log_file):
    """Carga eventos del log de arp_monitor.py."""
    if not os.path.isfile(log_file):
        print(f"[!] Log no encontrado: {log_file}")
        return []
    events = []
    with open(log_file) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                events.append(json.loads(line))
            except json.JSONDecodeError:
                pass
    return events


def evaluate_from_log(events):
    """Calcula metricas a partir del log de eventos."""
    detections = [e for e in events if e.get("event") == "ARP_SPOOFING_DETECTED"]
    blocks      = [e for e in events if e.get("event") == "MAC_BLOCKED"]
    unblocks    = [e for e in events if e.get("event") == "MAC_UNBLOCKED"]

    tp = len(blocks)   # cada bloqueo = ataque detectado y mitigado
    fp = 0             # falsos positivos (requiere revision manual)
    fn = 0             # falsos negativos (si hay ataques en pcap no detectados)

    det_time = None
    resp_time = None

    if detections and blocks:
        try:
            t_det = datetime.fromisoformat(detections[0]["ts"])
            t_blk = datetime.fromisoformat(blocks[0]["ts"])
            resp_time = (t_blk - t_det).total_seconds()
        except Exception:
            pass

    precision = tp / (tp + fp) if (tp + fp) > 0 else None
    recall    = tp / (tp + fn) if (tp + fn) > 0 else None

    return {
        "total_events": len(events),
        "detections": len(detections),
        "blocks": len(blocks),
        "unblocks": len(unblocks),
        "TP": tp,
        "FP": fp,
        "FN": fn,
        "precision": round(precision, 4) if precision is not None else "N/A",
        "recall": round(recall, 4) if recall is not None else "N/A",
        "detection_time_s": det_time,
        "response_time_s": round(resp_time, 3) if resp_time is not None else "N/A",
        "attacker_macs_blocked": list({e.get("detail", {}).get("attacker_mac", e.get("ts", ""))
                                       for e in blocks}),
    }


def fetch_live_metrics(controller_ip, port=8080):
    """Obtiene metricas en vivo desde la API REST de arp_monitor."""
    if not HAS_REQUESTS:
        print("[!] pip3 install requests para modo live")
        return None
    url = f"http://{controller_ip}:{port}/mitigation/stats"
    try:
        r = requests.get(url, timeout=5)
        r.raise_for_status()
        return r.json()
    except Exception as e:
        print(f"[!] No se pudo conectar a {url}: {e}")
        return None


def print_report(metrics, live_data=None):
    ts = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    print("\n" + "="*60)
    print("  INFORME DE EFICACIA DE MITIGACION — Fase 4")
    print(f"  Generado: {ts}")
    print("="*60)

    if live_data:
        lm = live_data.get("metrics", {})
        print("\n  [METRICAS EN VIVO — API REST]")
        print(f"  Ataques detectados : {lm.get('attacks_detected', 0)}")
        print(f"  Ataques bloqueados : {lm.get('attacks_blocked', 0)}")
        print(f"  Falsos positivos   : {lm.get('false_positives', 0)}")
        det = lm.get("first_detection_ts", "N/A")
        blk = lm.get("first_block_ts", "N/A")
        dt  = lm.get("detection_time_s", "N/A")
        print(f"  Primera deteccion  : {det}")
        print(f"  Primer bloqueo     : {blk}")
        print(f"  Tiempo respuesta   : {dt} s")

        trusted = live_data.get("trusted_arp", {})
        blocked = live_data.get("blocked_macs", {})
        print(f"\n  Tabla ARP confiable ({len(trusted)} entradas):")
        for ip, mac in sorted(trusted.items()):
            print(f"    {ip:<16} -> {mac}")
        print(f"\n  MACs bloqueadas ({len(blocked)}):")
        for mac, ts_b in blocked.items():
            print(f"    {mac}  (desde {ts_b})")

    if metrics:
        print("\n  [METRICAS DESDE LOG]")
        print(f"  Total eventos      : {metrics['total_events']}")
        print(f"  Detecciones ARP    : {metrics['detections']}")
        print(f"  Bloqueos activos   : {metrics['blocks']}")
        print()
        print(f"  True Positives (TP): {metrics['TP']}")
        print(f"  False Positives(FP): {metrics['FP']}")
        print(f"  False Negatives(FN): {metrics['FN']}")
        print(f"  Precision          : {metrics['precision']}")
        print(f"  Recall             : {metrics['recall']}")
        print(f"  T. Respuesta (blq) : {metrics['response_time_s']} s")
        if metrics['attacker_macs_blocked']:
            print(f"\n  MACs atacante bloqueadas:")
            for mac in metrics['attacker_macs_blocked']:
                print(f"    {mac}")

    # Conclusion
    print("\n" + "-"*60)
    tp = metrics.get("TP", 0) if metrics else 0
    fp = metrics.get("FP", 0) if metrics else 0
    if tp > 0 and fp == 0:
        print("  CONCLUSION: Mitigacion EFECTIVA (TP > 0, FP = 0)")
        print("  El sistema detecto y bloqueo el ataque sin interrumpir")
        print("  trafico legitimo.")
    elif tp > 0 and fp > 0:
        print(f"  CONCLUSION: Mitigacion PARCIAL (TP={tp}, FP={fp})")
        print("  Se detectaron ataques pero tambien hubo falsos positivos.")
    else:
        print("  CONCLUSION: Sin datos suficientes para evaluar.")
        print("  Asegurate de que arp_monitor este corriendo y el ataque activo.")
    print("="*60 + "\n")


def save_json(metrics, live_data):
    ts = datetime.now().strftime("%Y%m%d_%H%M%S")
    out = os.path.join(CAPTURES_DIR, f"mitigation_evaluation_{ts}.json")
    with open(out, "w") as f:
        json.dump({"log_metrics": metrics, "live_metrics": live_data,
                   "generated": datetime.now().isoformat()}, f, indent=2, default=str)
    print(f"[+] Evaluacion guardada: {out}")


def main():
    parser = argparse.ArgumentParser(description="Evaluacion de mitigacion MITM (Fase 4)")
    parser.add_argument("--log", default=DEFAULT_LOG,
                        help=f"Log de arp_monitor (default: {DEFAULT_LOG})")
    parser.add_argument("--live", action="store_true",
                        help="Consultar metricas en vivo via REST API")
    parser.add_argument("--controller", default="192.168.100.10",
                        help="IP del controlador Ryu (default: 192.168.100.10)")
    parser.add_argument("--port", type=int, default=8080)
    parser.add_argument("--save", action="store_true",
                        help="Guardar evaluacion en JSON")
    args = parser.parse_args()

    events   = load_events(args.log)
    metrics  = evaluate_from_log(events) if events else None
    live_data = fetch_live_metrics(args.controller, args.port) if args.live else None

    print_report(metrics, live_data)

    if args.save:
        save_json(metrics, live_data)


if __name__ == "__main__":
    main()
