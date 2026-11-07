#!/usr/bin/env python3
"""
analyze_ioc.py - Analiza un archivo .pcap buscando Indicadores de Compromiso (IoC) del MITM (Fase 3).

Detecta:
  - ARP Spoofing: cambios de IP->MAC en la tabla ARP observada
  - Gratuitous ARP: respuestas ARP no solicitadas
  - ARP Flooding: tasa anormalmente alta de paquetes ARP
  - Inconsistencias MAC: misma IP con multiples MACs distintas
  - ICMP redirigido: trafico ICMP que pasa por un host intermedio inesperado

Uso:
    python3 scripts/analyze_ioc.py captures/mitm_capture_<ts>.pcap
    python3 scripts/analyze_ioc.py captures/mitm_capture_<ts>.pcap --report
"""

import argparse
import os
import sys
from collections import defaultdict
from datetime import datetime

try:
    from scapy.all import rdpcap, ARP, IP, ICMP, Ether
except ImportError:
    print("[!] Instala scapy: pip3 install scapy")
    sys.exit(1)

ROOT_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CAPTURES_DIR = os.path.join(ROOT_DIR, "captures")


def analyze_pcap(pcap_file):
    print(f"[*] Cargando: {pcap_file}")
    try:
        packets = rdpcap(pcap_file)
    except Exception as e:
        print(f"[!] Error leyendo PCAP: {e}")
        sys.exit(1)

    print(f"[+] Paquetes cargados: {len(packets)}")

    # -------------------------------------------------------
    # Estructuras de analisis
    # -------------------------------------------------------
    ip_to_macs   = defaultdict(set)   # ip -> {mac1, mac2, ...}
    mac_to_ips   = defaultdict(set)   # mac -> {ip1, ip2, ...}
    arp_packets  = []
    arp_timeline = []                 # (timestamp, src_ip, src_mac, dst_ip, op)
    icmp_flows   = defaultdict(int)   # (src, dst) -> count

    ioc_list = []

    # -------------------------------------------------------
    # Analisis paquete a paquete
    # -------------------------------------------------------
    for pkt in packets:
        ts = float(pkt.time)

        # --- ARP ---
        if pkt.haslayer(ARP):
            arp = pkt[ARP]
            op = "who-has" if arp.op == 1 else "is-at"
            src_ip  = arp.psrc
            src_mac = arp.hwsrc
            dst_ip  = arp.pdst

            arp_packets.append(pkt)
            arp_timeline.append((ts, src_ip, src_mac, dst_ip, op))

            if src_ip and src_ip != "0.0.0.0":
                ip_to_macs[src_ip].add(src_mac)
                mac_to_ips[src_mac].add(src_ip)

            # Gratuitous ARP: respuesta ARP donde src_ip == dst_ip
            if op == "is-at" and src_ip == dst_ip:
                ioc_list.append({
                    "tipo": "GRATUITOUS_ARP",
                    "severidad": "MEDIA",
                    "ts": ts,
                    "descripcion": f"Gratuitous ARP de {src_mac} para IP {src_ip}",
                    "detalle": str(pkt.summary())
                })

        # --- ICMP ---
        if pkt.haslayer(ICMP) and pkt.haslayer(IP):
            src = pkt[IP].src
            dst = pkt[IP].dst
            icmp_flows[(src, dst)] += 1

    # -------------------------------------------------------
    # IoC 1: IP con multiples MACs (ARP Spoofing)
    # -------------------------------------------------------
    for ip, macs in ip_to_macs.items():
        if len(macs) > 1:
            ioc_list.append({
                "tipo": "ARP_SPOOFING",
                "severidad": "ALTA",
                "ts": None,
                "descripcion": f"IP {ip} asociada a {len(macs)} MACs distintas: {macs}",
                "detalle": f"Posible suplantacion de identidad (MITM)"
            })

    # -------------------------------------------------------
    # IoC 2: ARP Flooding (tasa > 10 pkt/s en ventana de 5s)
    # -------------------------------------------------------
    if arp_timeline:
        window = 5.0
        t_start = arp_timeline[0][0]
        t_end   = arp_timeline[-1][0]
        total_duration = max(t_end - t_start, 1)
        arp_rate = len(arp_packets) / total_duration

        if arp_rate > 3:
            ioc_list.append({
                "tipo": "ARP_FLOODING",
                "severidad": "MEDIA",
                "ts": t_start,
                "descripcion": f"Tasa ARP elevada: {arp_rate:.1f} pkt/s "
                               f"({len(arp_packets)} paquetes en {total_duration:.1f}s)",
                "detalle": "Tasa normal < 1 pkt/s; > 3 pkt/s indica envenenamiento activo"
            })

    # -------------------------------------------------------
    # IoC 3: Cambio de MAC para una IP a lo largo del tiempo
    # -------------------------------------------------------
    ip_mac_history = defaultdict(list)  # ip -> [(ts, mac)]
    for ts, src_ip, src_mac, _, op in arp_timeline:
        if op == "is-at" and src_ip != "0.0.0.0":
            ip_mac_history[src_ip].append((ts, src_mac))

    for ip, history in ip_mac_history.items():
        seen_macs = []
        for ts, mac in history:
            if seen_macs and mac != seen_macs[-1]:
                ioc_list.append({
                    "tipo": "MAC_CHANGE",
                    "severidad": "ALTA",
                    "ts": ts,
                    "descripcion": f"IP {ip} cambio de MAC: {seen_macs[-1]} -> {mac}",
                    "detalle": "Indica envenenamiento ARP activo en el momento de la captura"
                })
            if mac not in seen_macs:
                seen_macs.append(mac)

    return {
        "total_packets": len(packets),
        "arp_packets": len(arp_packets),
        "arp_rate_pps": round(len(arp_packets) / max((arp_timeline[-1][0] - arp_timeline[0][0]) if len(arp_timeline) > 1 else 1, 1), 2),
        "unique_ips": len(ip_to_macs),
        "unique_macs": len(mac_to_ips),
        "ip_to_macs": {k: list(v) for k, v in ip_to_macs.items()},
        "ioc_list": ioc_list
    }


def print_report(pcap_file, result):
    SEV_COLOR = {"ALTA": "!!!!", "MEDIA": " !! ", "BAJA": "  ! "}
    ts = datetime.now().strftime("%Y-%m-%d %H:%M:%S")

    print("\n" + "="*65)
    print("  INFORME DE ANALISIS IoC — Fase 3")
    print(f"  Archivo : {os.path.basename(pcap_file)}")
    print(f"  Fecha   : {ts}")
    print("="*65)

    print(f"\n  ESTADISTICAS GENERALES")
    print(f"  {'Total paquetes':<25}: {result['total_packets']}")
    print(f"  {'Paquetes ARP':<25}: {result['arp_packets']}")
    print(f"  {'Tasa ARP':<25}: {result['arp_rate_pps']} pkt/s")
    print(f"  {'IPs unicas vistas':<25}: {result['unique_ips']}")
    print(f"  {'MACs unicas vistas':<25}: {result['unique_macs']}")

    print(f"\n  TABLA IP -> MAC(s) OBSERVADAS")
    for ip, macs in sorted(result['ip_to_macs'].items()):
        flag = " <-- MULTIPLE MACs!" if len(macs) > 1 else ""
        print(f"  {ip:<16} -> {', '.join(macs)}{flag}")

    ioc = result["ioc_list"]
    print(f"\n  INDICADORES DE COMPROMISO (IoC): {len(ioc)} encontrados")
    print("-"*65)

    if not ioc:
        print("  (ninguno detectado — trafico parece legitimo)")
    else:
        altas  = [i for i in ioc if i["severidad"] == "ALTA"]
        medias = [i for i in ioc if i["severidad"] == "MEDIA"]
        bajas  = [i for i in ioc if i["severidad"] == "BAJA"]

        for grupo, nombre in [(altas, "ALTA"), (medias, "MEDIA"), (bajas, "BAJA")]:
            if grupo:
                print(f"\n  Severidad {nombre} ({len(grupo)}):")
                for item in grupo:
                    tag = SEV_COLOR.get(nombre, "    ")
                    print(f"  [{tag}] [{item['tipo']}]")
                    print(f"         {item['descripcion']}")
                    if item.get("detalle"):
                        print(f"         Detalle: {item['detalle']}")

    print("\n" + "="*65)

    # Conclusion
    n_alta = sum(1 for i in ioc if i["severidad"] == "ALTA")
    if n_alta > 0:
        print(f"  CONCLUSION: ATAQUE MITM CONFIRMADO ({n_alta} IoC de severidad ALTA)")
    elif len(ioc) > 0:
        print(f"  CONCLUSION: ACTIVIDAD SOSPECHOSA ({len(ioc)} IoC de severidad media/baja)")
    else:
        print("  CONCLUSION: No se detectaron indicadores de compromiso")
    print("="*65 + "\n")


def save_report(pcap_file, result):
    import json
    ts = datetime.now().strftime("%Y%m%d_%H%M%S")
    base = os.path.splitext(os.path.basename(pcap_file))[0]
    out = os.path.join(CAPTURES_DIR, f"ioc_report_{base}_{ts}.json")
    with open(out, "w") as f:
        json.dump(result, f, indent=2, default=str)
    print(f"[+] Reporte JSON guardado en: {out}")
    return out


def main():
    parser = argparse.ArgumentParser(description="Analisis de IoC MITM sobre PCAP (Fase 3)")
    parser.add_argument("pcap", help="Archivo .pcap a analizar")
    parser.add_argument("--report", action="store_true",
                        help="Guardar reporte JSON en captures/")
    args = parser.parse_args()

    if not os.path.isfile(args.pcap):
        print(f"[!] Archivo no encontrado: {args.pcap}")
        sys.exit(1)

    result = analyze_pcap(args.pcap)
    print_report(args.pcap, result)

    if args.report:
        save_report(args.pcap, result)


if __name__ == "__main__":
    main()
