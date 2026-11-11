# Simulación en terminal (para máquinas con poca RAM)

Esta carpeta contiene una **simulación** del ataque MITM en SDN pensada para
mostrarle el flujo completo a los estudiantes **en una sola máquina Ubuntu, en
la terminal, sin entorno gráfico y con pocos recursos (8 GB de RAM)**.

> **Simulado, no emulado.** No levanta Mininet, ni Open vSwitch, ni Ryu, ni
> scapy, y **no necesita `sudo` ni internet**. Reproduce paso a paso —con las
> mismas IPs, MACs y nombres del laboratorio real— lo que ocurre en cada fase:
> las cachés ARP, la tabla de flujos del switch y la consola del controlador.
> Es una herramienta **didáctica** para explicar el ataque; el laboratorio real
> (ARP spoofing con tráfico de verdad) sigue en el resto del repositorio.

## Cómo ejecutarla

Solo necesitas **Python 3.6 o superior** (ya viene en Ubuntu):

```bash
python3 simulacion/simular_mitm.py
```

o, con el orquestador del laboratorio:

```bash
bash lab.sh simular
```

En modo normal avanzas de fase en fase pulsando **Enter** (ideal para explicar
cada paso mientras proyectas la pantalla).

## Opciones

| Opción | Para qué sirve |
|--------|----------------|
| `--auto` | Avanza solo, con pausas temporizadas (útil para proyectar sin tocar el teclado). |
| `--rapido` | Pausas más cortas. |
| `--sin-pausa` | Imprime todo de corrido (para revisar o guardar la salida). |
| `--sin-color` | Desactiva los colores ANSI (terminales sin soporte de color). |
| `--fase N` | Empieza en una fase concreta (1 a 6). |

Ejemplos:

```bash
python3 simulacion/simular_mitm.py --auto --rapido      # demo automática ágil
python3 simulacion/simular_mitm.py --fase 6             # saltar a la mitigación
python3 simulacion/simular_mitm.py --sin-pausa --sin-color > demo.txt  # guardar
```

## Las 6 fases

1. **Línea base** — la red funciona; el controlador SDN instala los flujos.
2. **ARP Spoofing** — h3 (atacante) envenena las cachés ARP de h1 y h2.
3. **Interceptación** — el tráfico h1↔h2 pasa por h3 (MITM activo, silencioso).
4. **Modificación** — h3 altera el contenido del mensaje al vuelo.
5. **Inyección SDN** — variante: h3 inyecta un flujo OpenFlow malicioso vía REST.
6. **Mitigación** — el controlador detecta el cambio de MAC, instala un flujo
   `DROP` y aísla al atacante; la red se restaura.

## Relación con el laboratorio real

Cada fase de la simulación refleja un componente real del repositorio:

| Fase | Componente real |
|------|-----------------|
| 1 | `controller/simple_switch_13.py`, `ovs/setup_ovs.sh` |
| 2–4 | `attack/arp_spoof.py`, `attack/mitm_intercept.py`, `attack/flow_inject.py` |
| 6 | `mitigation/arp_monitor.py` |

Cuando dispongas de más memoria y quieras ejecutar el ataque **de verdad**,
sigue la guía del `README.md` principal.
