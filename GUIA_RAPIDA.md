# Guía rápida del laboratorio (versión simplificada)

> Para la charla de ciberseguridad. Todo el lab se maneja con **un solo script**: `lab.sh`.

---

## Resumen en 1 minuto

El lab tiene **5 máquinas virtuales**:

| VM   | Rol                  | IP              |
|------|----------------------|-----------------|
| ryu  | Controlador SDN      | 192.168.100.10  |
| ovs  | Switch OpenFlow      | 192.168.100.20 / 10.0.0.1 |
| h1   | Víctima A            | 10.0.0.11       |
| h2   | Víctima B / servidor | 10.0.0.12       |
| h3   | **Atacante**         | 10.0.0.66       |

La historia que cuenta el lab:
1. **h1 le envía un mensaje a h2.** Viaja por la red SDN.
2. **El atacante (h3) se mete en medio** (ARP spoofing) y **ve** el mensaje.
3. **El atacante altera** el mensaje antes de que llegue a h2.
4. **Activamos la mitigación en Ryu** y el ataque queda **bloqueado**.

---

## Preparación (una sola vez, la hace el instructor)

1. Instala Ubuntu Server 22.04 en **una** VM base. Clona el repo dentro y ejecuta:
   ```bash
   git clone https://github.com/juanortizpa/demostracion-narino.git
   cd demostracion-narino
   bash lab.sh instalar
   ```
   Esto instala Ryu, Open vSwitch, Scapy y todo lo demás. Tarda unos minutos.
   (No hace falta `chmod`: `lab.sh` arregla los permisos solo.)
2. Apaga la VM base y **clónala 5 veces** en VirtualBox (marca *"Generar nuevas MAC"*).
   Nómbralas: `ryu`, `ovs`, `h1`, `h2`, `h3`.
3. En el **host Windows**, desde PowerShell:
   ```powershell
   cd host-windows
   .\crear-vms.ps1
   ```
   Esto pone las 5 VMs en la red interna `intnet` automáticamente (ovs con 2 adaptadores).
   > Si prefieres clonar también desde PowerShell: `.\crear-vms.ps1 -Base "nombre-de-tu-base"`

Entrega a cada grupo el archivo **OVA exportado** (o el disco de las VMs) por USB, para no instalar nada en clase.

---

## En clase (cada grupo)

Enciende las 5 VMs. En **cada una**, dentro del repo, un único comando:

```bash
bash lab.sh
```

La primera vez pide el **rol** (1=ryu, 2=ovs, 3=h1, 4=h2, 5=h3). Asigna la IP sola y queda guardado.
Las siguientes veces, `bash lab.sh` abre directo el menú de ese rol.

### Orden de arranque

1. **ryu** → opción **1** (controlador normal).
2. **ovs** → opción **1** (conectar el switch a Ryu).
3. **h1, h2, h3** → ya tienen IP; listos.

### La demostración (el momento bonito)

1. En **h2** → opción **2** (abrir buzón, dejar abierto).
2. En **h1** → opción **1**, escribe un mensaje → aparece en h2. *(comunicación normal)*
3. En **h3 (atacante)** → opción **1** (**atacar y ver**). El ARP spoofing se activa solo.
   Repite el paso 2: el atacante **ve** el mensaje pasar. (Ctrl+C para volver al menú.)
4. En **h3** → opción **2** (**atacar y alterar**): escribe la palabra a buscar y su reemplazo.
   Repite el paso 2: a h2 le llega el mensaje **modificado**. (Ctrl+C vuelve al menú y restaura la red.)
5. **La defensa:** en **ryu**, detén el controlador (Ctrl+C) y elige opción **2** (mitigación).
   Repite el ataque desde h3: Ryu **detecta y bloquea** al atacante.

> En h3 ya no necesitas abrir dos terminales: el ARP spoofing se enciende y se apaga solo
> con cada opción. Para cortar el ataque manualmente, usa la opción **3**.

---

## Si algo falla

- **Las VMs no se ven entre sí:** confirma que las 5 están en la red interna `intnet`
  (lo hace `crear-vms.ps1`). Prueba `ping 10.0.0.12` desde h1.
- **Perdí la IP al reiniciar:** ya no pasa — `lab.sh` la deja persistente con netplan.
  Si hiciera falta, `./lab.sh ip`.
- **`ryu-manager` no arranca:** debe usar el venv de Python 3.9; `lab.sh` lo activa solo.
- **Diagnóstico general:** `bash scripts/diagnose.sh`.
