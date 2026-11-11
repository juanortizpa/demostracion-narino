# Ataque Man-in-the-Middle en Redes SDN

**Implementación y Análisis de un Ataque Man-in-the-Middle en Entornos de Redes Definidas por Software (SDN): Interceptación, Modificación de Paquetes y Estrategias de Mitigación.**

Proyecto de la Especialización en Ciberseguridad. Implementa, analiza y mitiga un ataque MITM
mediante **ARP Spoofing** e inyección de flujos OpenFlow maliciosos en una red SDN emulada,
controlada por **Ryu** y conmutada por **Open vSwitch (OVS)**, usando **Scapy** y **Wireshark**.

> ⚠️ **Uso responsable.** Todo el material es exclusivamente para fines educativos y de investigación,
> dentro de un laboratorio virtualizado y aislado. No debe utilizarse contra redes o sistemas sobre los
> que no se tenga autorización explícita.

---

## 🚀 Inicio rápido (versión simplificada para talleres)

¿Solo quieres montar el lab y empezar? No sigas los pasos manuales de más abajo.
Usa el orquestador **`lab.sh`** y la guía corta:

1. En una VM base Ubuntu 22.04 (con internet por NAT), una sola vez:
   ```bash
   git clone https://github.com/juanortizpa/demostracion-narino.git
   cd demostracion-narino
   sudo bash lab.sh instalar
   ```
   El instalador es robusto: fuerza IPv4 en apt, y si la red bloquea el PPA
   deadsnakes (común en redes universitarias) **compila Python 3.9 desde
   fuente** automáticamente. No requiere `chmod` manual.
2. Deja la base lista para clonar: `bash lab.sh limpiar` (borra el rol y la IP
   de prueba). Luego `sudo shutdown now`.
3. Clona la base 5 veces (ryu, ovs, h1, h2, h3) con MACs nuevas.
4. En el host Windows: `host-windows\crear-vms.ps1 -Base "ubuntu-base"`
   (clona y cablea la topología en estrella con una red interna por enlace).
5. En cada VM: `bash lab.sh` y elige su rol. Listo.

👉 **Guía paso a paso completa (para principiantes):** [`GUIA_PASO_A_PASO.pdf`](GUIA_PASO_A_PASO.pdf)
y la versión corta [`GUIA_RAPIDA.md`](GUIA_RAPIDA.md)

El resto de este README documenta el procedimiento manual detallado y la teoría de cada fase.

---

## Plan del proyecto (4 fases)

| Fase | Objetivo | Estado |
|------|----------|--------|
| **Fase 1** | Preparación del entorno: VMs, OVS, Ryu, conectividad verificada | ✅ Completada |
| **Fase 2** | Implementación del ataque MITM (ARP Spoofing + inyección de flujos OpenFlow) | ✅ Completada |
| **Fase 3** | Recolección y análisis de evidencias (pcap, estadísticas de flujo, IoC) | En proseso |
| **Fase 4** | Mitigación activa en Ryu + evaluación de métricas (TP, FP, tiempos) | 🧪 En pruebas proximas|

---

## Arquitectura del laboratorio

```
Plano de control (192.168.100.0/24)
┌─────────────────────────────────────────────┐
│  ryu  192.168.100.10  (enp0s3)              │
│   │  OpenFlow 1.3 tcp:6653                  │
│  ovs  192.168.100.20  (enp0s3)              │
└─────────────────────────────────────────────┘

Plano de datos (10.0.0.0/24)
┌─────────────────────────────────────────────┐
│  ovs   10.0.0.1   (enp0s8 → br0)           │
│  h1    10.0.0.11  (enp0s3)  víctima A       │
│  h2    10.0.0.12  (enp0s3)  víctima B       │
│  h3    10.0.0.13  (enp0s3)  atacante        │
└─────────────────────────────────────────────┘

Todas las VMs conectadas via VirtualBox Internal Network "intnet"
```

---

## Requisitos

- **VirtualBox** (probado con 7.x)
- **GNS3** (opcional para visualizar topología, no requerido para conectividad)
- **5 VMs Ubuntu Server 22.04** clonadas desde una VM base:
  - `ryu` — controlador SDN
  - `ovs` — switch OpenFlow
  - `h1`, `h2`, `h3` — hosts (víctimas / atacante)

---

## Paso 1 — Crear las VMs en VirtualBox

Instala Ubuntu Server 22.04 en una VM base, luego **clona** 5 veces marcando
"Generar nuevas direcciones MAC para todos los adaptadores".

Nombres sugeridos: `ryu`, `ovs`, `h1`, `h2`, `h3`.

### Configuración de adaptadores de red (CRÍTICO)

> ⚠️ **Lección aprendida:** El Ethernet Switch de GNS3 presentó problemas para reenviar
> tráfico entre VMs de VirtualBox. La solución que funcionó es usar **VirtualBox Internal Network
> directamente**, sin depender del switch virtual de GNS3.

En VirtualBox → Configuración → Red, para **cada VM** (con las VMs **apagadas**):

| VM | Adaptador | Conectado a | Nombre |
|----|-----------|-------------|--------|
| ryu | Adaptador 1 | Red interna | `intnet` |
| ovs | Adaptador 1 | Red interna | `intnet` |
| ovs | Adaptador 2 | Red interna | `intnet` |
| h1 | Adaptador 1 | Red interna | `intnet` |
| h2 | Adaptador 1 | Red interna | `intnet` |
| h3 | Adaptador 1 | Red interna | `intnet` |

> El nombre **debe ser exactamente `intnet`** en todas las VMs para que se vean entre sí.
> En VirtualBox, dos adaptadores con el mismo nombre de red interna forman un segmento L2 compartido.

**Nota sobre GNS3:** Si usas GNS3 para visualizar la topología, configura los nodos con:
- ryu: 1 adaptador, ovs: 2 adaptadores, hosts: 1 adaptador cada uno.
- Marcar **"Allow GNS3 to use any configured VirtualBox adapter"** en las propiedades de cada nodo.
- El Ethernet Switch de GNS3 puede agregarse para visualización, pero la conectividad real
  depende de la configuración de VirtualBox, no del switch de GNS3.

---

## Paso 2 — Instalar dependencias (una sola vez)

Clona el repositorio en cada VM:
```bash
git clone <URL-del-repo> ~/proyecto-mitm
cd ~/proyecto-mitm
chmod +x scripts/*.sh ovs/*.sh hosts/*.sh attack/*.sh
```

### VM `ryu` — Controlador

Ryu 4.34 requiere Python 3.9 (no es compatible con Python 3.10+ de Ubuntu 22.04):

```bash
sudo apt-get update
sudo apt-get install -y software-properties-common
sudo add-apt-repository -y ppa:deadsnakes/ppa
sudo apt-get update
sudo apt-get install -y python3.9 python3.9-venv python3.9-dev

python3.9 -m venv ~/ryu-venv
source ~/ryu-venv/bin/activate
pip install --upgrade "pip<21" "setuptools==58.2.0" wheel
pip install "eventlet==0.30.2" "ryu==4.34" requests
ryu-manager --version   # debe imprimir: ryu-manager 4.34
```

### VM `ovs` — Switch

```bash
sudo apt-get update
sudo apt-get install -y openvswitch-switch
sudo systemctl enable openvswitch-switch
```

### VMs `h1`, `h2` — Víctimas

```bash
sudo apt-get update
sudo apt-get install -y tcpdump iproute2
```

### VM `h3` — Atacante

```bash
sudo apt-get update
sudo apt-get install -y python3-pip tcpdump iproute2
sudo apt-get install -y build-essential python3-dev libnetfilter-queue-dev libnfnetlink-dev curl netcat
pip3 install netfilterqueue requests scapy
```

---

## Paso 3 — Asignar IPs (cada sesión)

> ⚠️ Las IPs asignadas con `ip addr add` **no son persistentes**. Deben reasignarse
> cada vez que se reinician las VMs. Ver "Solución de problemas" para hacerlas persistentes.

### VM `ryu`
```bash
sudo ip link set enp0s3 up
sudo ip addr add 192.168.100.10/24 dev enp0s3
```

### VM `ovs`
```bash
sudo ip link set enp0s3 up
sudo ip addr add 192.168.100.20/24 dev enp0s3
sudo ip link set enp0s8 up
sudo ip addr add 10.0.0.1/24 dev enp0s8
```

### VM `h1`
```bash
sudo ip link set enp0s3 up
sudo ip addr add 10.0.0.11/24 dev enp0s3
```

### VM `h2`
```bash
sudo ip link set enp0s3 up
sudo ip addr add 10.0.0.12/24 dev enp0s3
```

### VM `h3`
```bash
sudo ip link set enp0s3 up
sudo ip addr add 10.0.0.13/24 dev enp0s3
```

---

## Paso 4 — Verificar conectividad base

Antes de iniciar OVS o Ryu, confirmar que todas las VMs se ven entre sí:

```bash
# Desde h1:
ping -c3 10.0.0.12    # h1 → h2  ✓
ping -c3 10.0.0.13    # h1 → h3  ✓
ping -c3 10.0.0.1     # h1 → ovs ✓

# Desde ryu:
ping -c3 192.168.100.20   # ryu → ovs ✓
```

Todos deben responder con **0% packet loss** antes de continuar.

---

## Paso 5 — Configurar OVS + Ryu (Fase 1)

### VM `ryu` — Iniciar controlador

```bash
source ~/ryu-venv/bin/activate

# Solo OpenFlow (básico):
ryu-manager ryu.app.simple_switch_13

# Con API REST (necesaria para Fase 2):
ryu-manager --wsapi-port 8080 ryu.app.simple_switch_13 ryu.app.ofctl_rest
```

### VM `ovs` — Configurar bridge OpenFlow

```bash
sudo systemctl start openvswitch-switch

# Crear bridge (solo si no existe)
sudo ovs-vsctl add-br br0

# Agregar puerto de datos al bridge
sudo ovs-vsctl add-port br0 enp0s8

# Conectar al controlador Ryu
sudo ovs-vsctl set-controller br0 tcp:192.168.100.10:6653

# Verificar estado
sudo ovs-vsctl show
```

El output de `ovs-vsctl show` debe incluir:
```
Controller "tcp:192.168.100.10:6653"
    is_connected: true
```

### Limpiar puertos fantasma (si aplica)

Si `ovs-vsctl show` muestra puertos con error `"could not open network device"`,
son residuos de sesiones anteriores. Elimínalos:
```bash
sudo ovs-vsctl del-port br0 enp0s9
sudo ovs-vsctl del-port br0 enp0s10
# Ajusta los nombres según lo que muestre ovs-vsctl show
```

---

## Paso 6 — Verificar Fase 1 completa

```bash
# En ovs — confirmar OpenFlow 1.3 activo:
sudo ovs-ofctl -O OpenFlow13 show br0
sudo ovs-ofctl -O OpenFlow13 dump-flows br0
# Resultado esperado:
#   priority=0 actions=CONTROLLER:65535
#   n_packets > 0 (confirma tráfico procesado)
```

La terminal de Ryu debe mostrar mensajes `packet in` de los MACs de las VMs.

### Checklist Fase 1

- [ ] Todas las VMs se pinchan entre sí (0% packet loss)
- [ ] `ovs-vsctl show` → `is_connected: true`
- [ ] `dump-flows` muestra: `priority=0 actions=CONTROLLER:65535`
- [ ] Terminal de Ryu muestra `packet in` de múltiples MACs

---

## Solución de problemas conocidos

### El Ethernet Switch de GNS3 no reenvía tráfico entre VMs

**Causa:** GNS3 no puede reconfigurar adaptadores de VMs que ya están corriendo, o hay
conflicto con el tipo de adaptador configurado en VirtualBox.

**Solución confirmada:** Apagar todas las VMs → configurar todos los adaptadores como
**Red interna → `intnet`** en VirtualBox → reiniciar.

---

### Error: "Attachment 'nat' is already configured on adapter 0" en GNS3

Marcar **"Allow GNS3 to use any configured VirtualBox adapter"** en las propiedades del nodo
en GNS3 (clic derecho → Configure → pestaña Network).

---

### enp0s8 en OVS muestra `master ovs-system` y no responde a ping

OVS tomó control de la interfaz en una sesión anterior. Para liberarla:
```bash
sudo systemctl start openvswitch-switch
sudo ovs-vsctl del-port br0 enp0s8
sudo systemctl stop openvswitch-switch
sudo ip addr flush dev enp0s8
sudo ip addr add 10.0.0.1/24 dev enp0s8
sudo ip link set enp0s8 up
```

---

### `ovs-ofctl show br0` falla con "version negotiation failed"

Ryu usa OpenFlow 1.3, pero `ovs-ofctl` usa 1.0 por defecto. Siempre agregar `-O OpenFlow13`:
```bash
sudo ovs-ofctl -O OpenFlow13 show br0
sudo ovs-ofctl -O OpenFlow13 dump-flows br0
```

---

### IPs perdidas al reiniciar las VMs

**Opción A:** Reasignar manualmente (Paso 3 de esta guía).

**Opción B — IPs persistentes con Netplan** (recomendado para evitar repetir cada sesión):
```yaml
# /etc/netplan/00-installer-config.yaml — ejemplo para h1
network:
  version: 2
  ethernets:
    enp0s3:
      addresses: [10.0.0.11/24]
      dhcp4: false
```
```bash
sudo netplan apply
```

Ajusta la IP según la VM. Para `ovs`, configura ambas interfaces (`enp0s3` y `enp0s8`).

---

## Estructura del repositorio

```
.
├── README.md
├── LICENSE
├── requirements.txt
├── controller/
│   └── simple_switch_13.py        # Controlador Ryu — learning switch OpenFlow 1.3
├── mitigation/                    # Fase 4: módulo de mitigación activa
│   ├── arp_monitor.py             # Ryu app con detección ARP Spoofing + bloqueo
│   ├── flow_anomaly.py            # Detector estadístico de anomalías en flujos
│   └── run_mitigation.sh          # Inicia Ryu en modo mitigación
├── ovs/
│   └── setup_ovs.sh               # Configura Open vSwitch y lo conecta a Ryu
├── hosts/
│   └── config_host.sh             # Asignación de IP por rol
├── attack/                        # Fase 2: módulo de ataque MITM
│   ├── arp_spoof.py               # ARP Spoofing (Scapy)
│   ├── flow_inject.py             # Inyección de flujos OpenFlow vía API REST
│   ├── mitm_intercept.py          # Interceptación/modificación de paquetes
│   ├── demo_traffic.sh            # Genera tráfico de prueba (ICMP/TCP/HTTP)
│   └── verify_mitm.sh             # Verifica que el MITM esté activo
├── scripts/
│   ├── setup_env.sh               # Instala dependencias según rol
│   ├── run_controller.sh          # Arranca Ryu (modo básico)
│   ├── diagnose.sh                # Diagnóstico completo del stack
│   ├── baseline_capture.sh        # Captura línea base de tráfico (pcap)
│   ├── collect_evidence.sh        # Captura evidencias durante el ataque (Fase 3)
│   ├── flow_stats.py              # Extrae estadísticas de flujo de Ryu (Fase 3)
│   ├── analyze_ioc.py             # Analiza IoC en capturas PCAP (Fase 3)
│   └── evaluate_mitigation.py     # Calcula TP, FP, tiempos de respuesta (Fase 4)
├── captures/                      # Artefactos generados (excluido de git)
│   └── .gitkeep
└── docs/
    ├── PLAN_GENERAL.md
    ├── FASE1.md
    ├── FASE2.md
    ├── FASE3.md
    ├── FASE4.md
    └── TOPOLOGIAS.md
```

---

## Herramientas

- **VirtualBox** — virtualización de VMs
- **GNS3** — visualización de topología (opcional)
- **Ryu** — controlador SDN en Python (OpenFlow 1.3)
- **Open vSwitch** — switch OpenFlow
- **Scapy** — construcción/inyección de paquetes (Fase 2)
- **Wireshark / tcpdump** — captura y análisis de tráfico

---

## Bitácora

- **Fase 1 — Semana 1:** Entorno configurado, conectividad 0% packet loss entre todas las VMs, OVS ↔ Ryu con OpenFlow 1.3 activo (`is_connected: true`). ✅
- **Fase 2 — Semana 2:** ARP Spoofing funcional desde h3 — MITM confirmado por tabla ARP de víctima. ✅
- **Fase 3 — Semana 3:** Scripts de captura, extracción de flujos y análisis IoC implementados. ✅
- **Fase 4 — Semana 4:** Módulo de mitigación (`arp_monitor.py`) implementado. En pruebas. 🧪
