<#
=====================================================================
 crear-vms.ps1  -  Configura (y opcionalmente clona) las 5 VMs del lab
                   MITM en SDN directamente en VirtualBox, desde Windows.
=====================================================================

 Elimina el paso manual mas doloroso: entrar VM por VM a VirtualBox y
 cablear cada adaptador a la red interna correcta. Este script lo hace
 por ti y deja la TOPOLOGIA EN ESTRELLA correcta:

   - Plano de CONTROL (OpenFlow):  red interna 'lab-ctrl'
        ryu.nic1  <-> ovs.nic1
   - Plano de DATOS (un enlace dedicado por host, para que TODO el
     trafico pase por OVS y Ryu lo pueda ver y mitigar):
        ovs.nic2 <-> h1.nic1   (red interna 'lab-h1')
        ovs.nic3 <-> h2.nic1   (red interna 'lab-h2')
        ovs.nic4 <-> h3.nic1   (red interna 'lab-h3')

 IMPORTANTE: NO se usa una sola red interna para todos. Si h1 y h2
 estuvieran en el mismo segmento, se hablarian directo SIN pasar por
 OVS, y la demostracion de mitigacion en Ryu no funcionaria.

 USO (PowerShell en el host Windows):

   # Caso A: ya tienes 5 VMs creadas (ryu, ovs, h1, h2, h3)
   #         -> solo configura sus redes internas:
   .\crear-vms.ps1

   # Caso B: tienes una VM base ya instalada y quieres clonar las 5:
   .\crear-vms.ps1 -Base "ubuntu-base"

 Resultado: las 5 VMs quedan cableadas en estrella. Luego enciende las
 VMs y en cada una ejecuta:  bash lab.sh   y elige su rol.

 Requisito: VirtualBox 7.x instalado (VBoxManage en el PATH o en la
 ruta estandar de instalacion).
=====================================================================
#>

param(
    [string]$Base      = "",            # nombre de la VM base para clonar (opcional)
    [string]$Ctrl      = "lab-ctrl",    # red interna del plano de control
    [string]$NetH1     = "lab-h1",      # enlace dedicado ovs<->h1
    [string]$NetH2     = "lab-h2",      # enlace dedicado ovs<->h2
    [string]$NetH3     = "lab-h3",      # enlace dedicado ovs<->h3
    [int]$MemMB        = 1024,          # RAM por VM (1 GB basta para Ubuntu Server)
    [switch]$NoApagar                   # no intentar apagar las VMs antes de reconfigurar
)

$ErrorActionPreference = "Stop"

# --- Localizar VBoxManage -------------------------------------------
function Get-VBoxManage {
    $cmd = Get-Command VBoxManage -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $def = "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe"
    if (Test-Path $def) { return $def }
    throw "No se encontro VBoxManage. Instala VirtualBox 7.x o agrega VBoxManage al PATH."
}
$VBM = Get-VBoxManage
Write-Host "==> Usando VBoxManage: $VBM" -ForegroundColor Cyan

# --- Definicion de VMs y sus adaptadores -----------------------------
# 'Nets' lista la red interna de cada adaptador en orden (nic1, nic2, ...).
# La VM 'ovs' lleva 4 adaptadores (1 de control + 3 enlaces de datos);
# las demas, 1.
$VMs = @(
    @{ Name = "ryu"; Nets = @($Ctrl) },
    @{ Name = "ovs"; Nets = @($Ctrl, $NetH1, $NetH2, $NetH3) },
    @{ Name = "h1";  Nets = @($NetH1) },
    @{ Name = "h2";  Nets = @($NetH2) },
    @{ Name = "h3";  Nets = @($NetH3) }
)

function VM-Existe($name) {
    $list = & $VBM list vms
    return ($list -match ("`"" + [regex]::Escape($name) + "`""))
}

function VM-Apagada($name) {
    $info = & $VBM showvminfo $name --machinereadable 2>$null
    if ($info -match 'VMState="poweroff"' -or $info -match 'VMState="aborted"' -or $info -match 'VMState="saved"') {
        return $true
    }
    return $false
}

# --- Clonado opcional desde una base --------------------------------
if ($Base -ne "") {
    if (-not (VM-Existe $Base)) { throw "La VM base '$Base' no existe en VirtualBox." }
    Write-Host "==> Clonando desde la base '$Base' (MACs nuevas)..." -ForegroundColor Cyan
    foreach ($vm in $VMs) {
        if (VM-Existe $vm.Name) {
            Write-Host "    - $($vm.Name) ya existe, no se clona." -ForegroundColor Yellow
        } else {
            Write-Host "    + Clonando $($vm.Name)..." -ForegroundColor Green
            & $VBM clonevm $Base --name $vm.Name --register --mode machine | Out-Null
        }
    }
}

# --- Configuracion de red de cada VM --------------------------------
foreach ($vm in $VMs) {
    $name = $vm.Name
    if (-not (VM-Existe $name)) {
        Write-Host "[!] La VM '$name' no existe. Creala o usa -Base para clonar." -ForegroundColor Yellow
        continue
    }

    if (-not $NoApagar -and -not (VM-Apagada $name)) {
        Write-Host "==> Apagando '$name' para reconfigurar la red..." -ForegroundColor Cyan
        & $VBM controlvm $name poweroff 2>$null | Out-Null
        Start-Sleep -Seconds 2
    }

    $desc = ($vm.Nets -join ", ")
    Write-Host "==> Configurando red de '$name' ($($vm.Nets.Count) adaptador/es: $desc)" -ForegroundColor Cyan
    & $VBM modifyvm $name --memory $MemMB | Out-Null

    # Cablea cada adaptador a su red interna correspondiente.
    $i = 1
    foreach ($net in $vm.Nets) {
        & $VBM modifyvm $name "--nic$i" intnet "--intnet$i" $net "--cableconnected$i" on | Out-Null
        Write-Host "    nic$i -> intnet '$net'" -ForegroundColor DarkGray
        $i++
    }
    # Apaga los adaptadores sobrantes (hasta el 4) por limpieza.
    for (; $i -le 4; $i++) {
        & $VBM modifyvm $name "--nic$i" none | Out-Null
    }

    Write-Host "    [OK] $name listo." -ForegroundColor Green
}

Write-Host ""
Write-Host "=====================================================================" -ForegroundColor Cyan
Write-Host " Listo. Topologia en estrella cableada:" -ForegroundColor Green
Write-Host "   Control: ryu <-> ovs           (red interna '$Ctrl')" -ForegroundColor Green
Write-Host "   Datos:   ovs <-> h1            (red interna '$NetH1')" -ForegroundColor Green
Write-Host "            ovs <-> h2            (red interna '$NetH2')" -ForegroundColor Green
Write-Host "            ovs <-> h3            (red interna '$NetH3')" -ForegroundColor Green
Write-Host ""
Write-Host " Siguiente paso:" -ForegroundColor Cyan
Write-Host "   1) Enciende las 5 VMs."
Write-Host "   2) En cada una ejecuta:  bash lab.sh   y elige su rol."
Write-Host "      (ryu=1  ovs=2  h1=3  h2=4  h3=5)"
Write-Host "   3) Orden de arranque: ryu (opcion 1) -> ovs (opcion 1) -> hosts."
Write-Host "=====================================================================" -ForegroundColor Cyan
