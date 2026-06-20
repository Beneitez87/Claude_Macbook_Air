<#
.SYNOPSIS
    Aprovisiona los prerrequisitos de Microsoft Graph para
    EnterpriseApp_Lifecycle.ps1 en Windows Server 2022+ (Windows PowerShell 5.1)
    o PowerShell 7+.

.DESCRIPTION
    Script idempotente y autocontenido. Ejecutar UNA VEZ en el servidor (como
    administrador si -Scope AllUsers). Realiza:
      1. Fuerza TLS 1.2 (PSGallery lo exige en Windows PowerShell 5.1).
      2. Asegura el proveedor de paquetes NuGet.
      3. Marca PSGallery como repositorio de confianza (instalación no interactiva).
      4. Instala los 5 submódulos de Microsoft.Graph necesarios.
      5. Verifica que cada módulo importa correctamente.

    Devuelve un JSON estructurado (success / message / timestamp / data) y código
    de salida 0 (éxito) o 1 (error), igual que el script de ciclo de vida.

.PARAMETER Scope
    Ámbito de instalación: AllUsers (por defecto; requiere ejecutar como
    administrador) o CurrentUser.

.PARAMETER ModuleVersion
    (Opcional) Versión exacta de los módulos Microsoft.Graph a instalar
    (p.ej. "2.38.0"). Por defecto, la última disponible en PSGallery.

.PARAMETER CheckOnly
    Solo verifica el estado de los módulos sin instalar nada. Útil como
    health-check periódico.

.EXAMPLE
    # Aprovisionar el servidor (sesión de PowerShell como administrador)
    .\Install-GraphPrerequisites.ps1

.EXAMPLE
    # Comprobar el estado sin instalar
    .\Install-GraphPrerequisites.ps1 -CheckOnly

.NOTES
    Compatible con Windows PowerShell 5.1+ y PowerShell 7+.
    Requiere acceso de red a https://www.powershellgallery.com (o un repositorio
    interno equivalente). Si la directiva de ejecución lo impide, invoque:
        powershell.exe -ExecutionPolicy Bypass -File .\Install-GraphPrerequisites.ps1
#>

#Requires -Version 5.1

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '',
    Justification = 'Write-Host solo se usa para progreso durante la instalación; el resultado se emite siempre por Write-Output en formato JSON.')]
[CmdletBinding()]
param(
    [ValidateSet("AllUsers", "CurrentUser")]
    [string] $Scope = "AllUsers",

    [string] $ModuleVersion,

    [switch] $CheckOnly
)

$ErrorActionPreference = "Stop"

$Modules = @(
    "Microsoft.Graph.Authentication",
    "Microsoft.Graph.Applications",
    "Microsoft.Graph.Users",
    "Microsoft.Graph.Identity.SignIns",
    "Microsoft.Graph.DirectoryObjects"
)

function Write-Result {
    param(
        [bool]   $Success,
        [string] $Message,
        [object] $Data = $null
    )
    $result = [ordered]@{
        success   = $Success
        message   = $Message
        timestamp = ([DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ"))
        data      = $Data
    }
    Write-Output ($result | ConvertTo-Json -Depth 6 -Compress)
    exit $(if ($Success) { 0 } else { 1 })
}

# ¿Estamos en Windows? (en PS 5.1 $IsWindows no existe -> es Windows)
$onWindows = if ($null -eq $IsWindows) { $true } else { $IsWindows }

$data = [ordered]@{
    powershell = "$($PSVersionTable.PSEdition) $($PSVersionTable.PSVersion)"
    scope      = $Scope
    checkOnly  = [bool]$CheckOnly
    modules    = @()
}

# Aviso temprano: AllUsers requiere privilegios de administrador en Windows.
if (-not $CheckOnly -and $Scope -eq "AllUsers" -and $onWindows) {
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) {
        Write-Result -Success $false -Message "El ámbito 'AllUsers' requiere ejecutar PowerShell como administrador. Use -Scope CurrentUser o eleve la sesión." -Data $data
    }
}

try {
    if (-not $CheckOnly) {
        # 1. TLS 1.2 (requerido por PSGallery en Windows PowerShell 5.1)
        try {
            [Net.ServicePointManager]::SecurityProtocol =
                [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        }
        catch {
            Write-Verbose "No se pudo ajustar TLS 1.2: $($_.Exception.Message)"
        }

        # 2. Proveedor NuGet
        if (-not (Get-PackageProvider -Name NuGet -ListAvailable -ErrorAction SilentlyContinue)) {
            Write-Host "Instalando proveedor NuGet..." -ForegroundColor Yellow
            Install-PackageProvider -Name NuGet -MinimumVersion '2.8.5.201' -Scope $Scope -Force -ErrorAction Stop | Out-Null
        }

        # 3. Confiar en PSGallery (instalación no interactiva)
        $gallery = Get-PSRepository -Name PSGallery -ErrorAction SilentlyContinue
        if ($gallery -and $gallery.InstallationPolicy -ne 'Trusted') {
            Set-PSRepository -Name PSGallery -InstallationPolicy Trusted -ErrorAction SilentlyContinue
        }
    }

    # 4 + 5. Instalar (si procede) y verificar cada módulo
    foreach ($m in $Modules) {
        $present = Get-Module -ListAvailable -Name $m | Sort-Object Version -Descending | Select-Object -First 1
        $needInstall = (-not $present) -or ($ModuleVersion -and $present.Version.ToString() -ne $ModuleVersion)

        if ($needInstall -and -not $CheckOnly) {
            Write-Host "Instalando $m..." -ForegroundColor Yellow
            $installParams = @{
                Name         = $m
                Scope        = $Scope
                Force        = $true
                AllowClobber = $true
                ErrorAction  = 'Stop'
            }
            if ($ModuleVersion) { $installParams.RequiredVersion = $ModuleVersion }
            Install-Module @installParams
            $present = Get-Module -ListAvailable -Name $m | Sort-Object Version -Descending | Select-Object -First 1
        }

        # Verificar que importa (solo cuando no es CheckOnly, para no penalizar el health-check)
        $importable = $null
        if (-not $CheckOnly -and $present) {
            try {
                Import-Module -Name $m -RequiredVersion $present.Version -ErrorAction Stop
                $importable = $true
            }
            catch {
                $importable = $false
            }
        }

        $data.modules += [ordered]@{
            name       = $m
            installed  = [bool]$present
            version    = if ($present) { $present.Version.ToString() } else { $null }
            importable = $importable
        }
    }

    # Evaluar resultado
    $failed = $data.modules | Where-Object {
        (-not $_.installed) -or ($_.importable -eq $false)
    }

    if ($failed) {
        $names = ($failed | ForEach-Object { $_.name }) -join ", "
        if ($CheckOnly) {
            Write-Result -Success $false -Message "Faltan módulos: $names. Ejecute sin -CheckOnly para instalarlos." -Data $data
        }
        else {
            Write-Result -Success $false -Message "Tras la instalación, estos módulos no están disponibles: $names." -Data $data
        }
    }

    $verbo = if ($CheckOnly) { "verificados (presentes)" } else { "instalados y verificados" }
    Write-Result -Success $true -Message "Los $($Modules.Count) módulos de Microsoft Graph están $verbo correctamente." -Data $data
}
catch {
    Write-Result -Success $false -Message "Error durante el aprovisionamiento: $($_.Exception.Message)" -Data $data
}
