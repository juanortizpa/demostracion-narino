<#
=====================================================================
 crear-vms.ps1  -  Configura (y opcionalmente clona) las 5 VMs del lab
                   MITM en SDN directamente en VirtualBox, desde Windows.
=====================================================================

 Elimina el paso manual mas doloroso: entrar VM por VM a VirtualBox y
 poner cada adaptador en "Red interna / intnet". Este script lo hace por ti.

 USO (PowerShell en el host Windows):

   # Caso A: ya tienes 5 VMs creadas (ryu, ovs, h1, h2, h3)
   #         -> solo configura sus redes internas:
   .\crear-vms.ps1

   # Caso B: tienes una VM base ya instalada y quieres clonar las 5:
   .\crear-vms.ps1 -Base "lab-base"

 Resultado: las 5 VMs quedan en la red interna 'intnet'; 'ovs' con 2
 adaptadores y las demas con 1. Luego enciende las VMs y en cada una
 ejecuta:  ./lab.sh

 Requisito: VirtualBox 7.x instalado (VBoxManage en el PATH o en la
 ruta estandar de instalacion).
=====================================================================
#>

param(
    [string]$Base = "",                 # nombre de la VM base para clonar (opcional)
    [string]$IntNet = "intnet",         # nombre de la red interna (debe ser igual en todas)
    [int]$MemMB = 1024,                 # RAM por VM (1 GB basta para Ubuntu Server minimal)
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

# La VM 'ovs' lleva 2 adaptadores; las demas, 1.
$VMs = @(
    @{ Name = "ryu"; Nics = 1 },
    @{ Name = "ovs"; Nics = 2 },
    @{ Name = "h1";  Nics = 1 },
    @{ Name = "h2";  Nics = 1 },
    @{ Name = "h3";  Nics = 1 }
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

    Write-Host "==> Configurando red de '$name' ($($vm.Nics) adaptador/es en '$IntNet')" -ForegroundColor Cyan
    & $VBM modifyvm $name --memory $MemMB | Out-Null

    # Adaptador 1 -> red interna
    & $VBM modifyvm $name --nic1 intnet --intnet1 $IntNet --cableconnected1 on | Out-Null

    if ($vm.Nics -ge 2) {
        # Adaptador 2 -> misma red interna (solo 'ovs')
        & $VBM modifyvm $name --nic2 intnet --intnet2 $IntNet --cableconnected2 on | Out-Null
    } else {
        # Asegurar que no queden adaptadores extra conectados
        & $VBM modifyvm $name --nic2 none | Out-Null
    }
    # Apagar adaptadores 3/4 por limpieza
    & $VBM modifyvm $name --nic3 none --nic4 none | Out-Null

    Write-Host "    [OK] $name listo." -ForegroundColor Green
}

Write-Host ""
Write-Host "=====================================================================" -ForegroundColor Cyan
Write-Host " Listo. Las 5 VMs estan en la red interna '$IntNet'." -ForegroundColor Green
Write-Host " Siguiente paso:" -ForegroundColor Cyan
Write-Host "   1) Enciende las 5 VMs."
Write-Host "   2) En cada una ejecuta:  ./lab.sh   y elige su rol."
Write-Host "      (ryu=1  ovs=2  h1=3  h2=4  h3=5)"
Write-Host "=====================================================================" -ForegroundColor Cyan
