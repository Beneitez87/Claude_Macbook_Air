<#
.SYNOPSIS
    Fase 1 - Gestión de usuarios y grupos en Enterprise Apps (Entra ID)
    Añade o elimina la asignación de un usuario o grupo a una enterprise app.

.DESCRIPTION
    Utiliza Microsoft Graph (vía SDK Microsoft.Graph) con autenticación
    client credentials (client_id + secret). Diseñado para ser invocado
    desde ServiceNow (MID Server o REST step).

    Devuelve un JSON estructurado con el resultado de la operación,
    legible por ServiceNow para gestión de errores y trazabilidad.

.PARAMETER TenantId
    ID del tenant de Entra ID.

.PARAMETER ClientId
    App ID (client_id) de la enterprise app ejecutora.

.PARAMETER ClientSecret
    Secret de la enterprise app ejecutora.

.PARAMETER ServicePrincipalId
    ObjectId del service principal (enterprise app) sobre la que operar.

.PARAMETER Action
    Operación a realizar: "Add" o "Remove".

.PARAMETER PrincipalId
    ObjectId del usuario o grupo a asignar o desasignar.

.PARAMETER AppRoleId
    (Opcional) ID del app role a asignar. Si no se especifica, se usa
    el rol por defecto (00000000-0000-0000-0000-000000000000).

.EXAMPLE
    # Añadir un usuario
    .\Fase1_Gestión_Usuarios_EnterpriseApp.ps1 `
        -TenantId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
        -ClientId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
        -ClientSecret "your-secret-here" `
        -ServicePrincipalId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
        -Action "Add" `
        -PrincipalId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"

.EXAMPLE
    # Eliminar un grupo
    .\Fase1_Gestión_Usuarios_EnterpriseApp.ps1 `
        -TenantId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
        -ClientId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
        -ClientSecret "your-secret-here" `
        -ServicePrincipalId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
        -Action "Remove" `
        -PrincipalId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"

.NOTES
    Módulos requeridos: Microsoft.Graph.Authentication, Microsoft.Graph.Applications,
                        Microsoft.Graph.DirectoryObjects
    Permisos Graph (tipo Application) del ejecutor:
        AppRoleAssignment.ReadWrite.All  -> crear/eliminar y leer asignaciones de app role
        Application.Read.All             -> leer el service principal destino (paso 3)
        Directory.Read.All               -> resolver el tipo del principal con Get-MgDirectoryObject (paso 4)
#>

#Requires -Version 5.1

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingConvertToSecureStringWithPlainText', '',
    Justification = 'Conversión inevitable: el client secret del flujo client-credentials debe pasarse como SecureString a New-Object PSCredential. No se persiste en claro.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '',
    Justification = 'Write-Host solo se usa para diagnóstico durante la instalación de módulos en primer arranque; el resultado de la operación se emite siempre por Write-Output en formato JSON.')]
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $TenantId,
    [Parameter(Mandatory)] [string] $ClientId,
    [Parameter(Mandatory)] [string] $ClientSecret,
    [Parameter(Mandatory)] [string] $ServicePrincipalId,
    [Parameter(Mandatory)] [ValidateSet("Add", "Remove")] [string] $Action,
    [Parameter(Mandatory)] [string] $PrincipalId,
    [string] $AppRoleId = "00000000-0000-0000-0000-000000000000"
)

# Que cualquier error no controlado detenga el script y caiga en el catch
# correspondiente. Los cmdlets con -ErrorAction explícito mantienen su propio
# comportamiento.
$ErrorActionPreference = "Stop"

# ─────────────────────────────────────────────
# FUNCIONES AUXILIARES
# ─────────────────────────────────────────────

function Write-Result {
    <#
    .SYNOPSIS
        Escribe el resultado final en JSON y termina el script.
        ServiceNow parsea este JSON para determinar éxito o error.
    #>
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
    Write-Output ($result | ConvertTo-Json -Depth 5 -Compress)
    exit $(if ($Success) { 0 } else { 1 })
}

function Test-IsGuid {
    <#
    .SYNOPSIS
        Valida que una cadena tenga formato GUID. Permite detectar parámetros
        mal formados antes de llamar a Graph, devolviendo un error claro.
    #>
    param([string] $Value)
    [guid]::TryParse($Value, [ref]([guid]::Empty))
}

function Get-PrincipalType {
    <#
    .SYNOPSIS
        Determina si un ObjectId corresponde a un usuario, grupo o service
        principal. Devuelve "User", "Group", "ServicePrincipal" o lanza
        excepción si no se encuentra o el tipo no está soportado.
    #>
    param([string] $ObjectId)

    $dirObject = Get-MgDirectoryObject -DirectoryObjectId $ObjectId -ErrorAction SilentlyContinue

    if (-not $dirObject) {
        throw "No se encontró ningún objeto de directorio con ObjectId: $ObjectId"
    }

    # El SDK de Microsoft.Graph expone el tipo derivado en
    # AdditionalProperties['@odata.type']; la propiedad fuerte .ODataType
    # suele venir vacía, por lo que no se puede confiar solo en ella.
    $odataType = $null
    if ($dirObject.AdditionalProperties -and $dirObject.AdditionalProperties.ContainsKey('@odata.type')) {
        $odataType = $dirObject.AdditionalProperties['@odata.type']
    }
    if (-not $odataType) { $odataType = $dirObject.ODataType }

    switch ($odataType) {
        "#microsoft.graph.user"             { return "User" }
        "#microsoft.graph.group"            { return "Group" }
        "#microsoft.graph.servicePrincipal" { return "ServicePrincipal" }
        default {
            throw "El ObjectId '$ObjectId' corresponde a un tipo no soportado: $odataType. Solo se admiten usuarios, grupos y service principals."
        }
    }
}

function Get-ExistingAssignment {
    <#
    .SYNOPSIS
        Busca una asignación existente del principal en el service principal.
        Devuelve el objeto de asignación o $null si no existe.
    #>
    param(
        [string] $SpId,
        [string] $PrinId,
        [string] $RoleId
    )

    Get-MgServicePrincipalAppRoleAssignedTo -ServicePrincipalId $SpId -All |
        Where-Object { $_.PrincipalId -eq $PrinId -and $_.AppRoleId -eq $RoleId } |
        Select-Object -First 1
}

# ─────────────────────────────────────────────
# 0. VALIDAR FORMATO DE LOS PARÁMETROS
# ─────────────────────────────────────────────

foreach ($p in @(
    @{ Name = "TenantId";           Value = $TenantId },
    @{ Name = "ClientId";           Value = $ClientId },
    @{ Name = "ServicePrincipalId"; Value = $ServicePrincipalId },
    @{ Name = "PrincipalId";        Value = $PrincipalId },
    @{ Name = "AppRoleId";          Value = $AppRoleId }
)) {
    if (-not (Test-IsGuid -Value $p.Value)) {
        Write-Result -Success $false -Message "El parámetro '$($p.Name)' no tiene un formato GUID válido: '$($p.Value)'."
    }
}

# ─────────────────────────────────────────────
# 1. VERIFICAR, INSTALAR E IMPORTAR MÓDULOS
# ─────────────────────────────────────────────

$requiredModules = @(
    "Microsoft.Graph.Authentication",
    "Microsoft.Graph.Applications",
    "Microsoft.Graph.DirectoryObjects"
)

foreach ($module in $requiredModules) {
    if (-not (Get-Module -ListAvailable -Name $module)) {
        Write-Host "Módulo '$module' no encontrado. Instalando..." -ForegroundColor Yellow
        try {
            # Endurecer la instalación para entornos no interactivos (MID Server):
            # sin esto, un proveedor NuGet ausente o un PSGallery no confiable
            # provocan un prompt que bloquea la ejecución indefinidamente.
            if (-not (Get-PackageProvider -Name NuGet -ListAvailable -ErrorAction SilentlyContinue)) {
                Install-PackageProvider -Name NuGet -Scope CurrentUser -Force -ErrorAction Stop | Out-Null
            }
            $gallery = Get-PSRepository -Name PSGallery -ErrorAction SilentlyContinue
            if ($gallery -and $gallery.InstallationPolicy -ne 'Trusted') {
                Set-PSRepository -Name PSGallery -InstallationPolicy Trusted -ErrorAction SilentlyContinue
            }

            Install-Module -Name $module -Scope CurrentUser -Force -AllowClobber -ErrorAction Stop
            Write-Host "Módulo '$module' instalado correctamente." -ForegroundColor Green
        }
        catch {
            Write-Result -Success $false -Message "No se pudo instalar el módulo '$module': $($_.Exception.Message)"
        }
    }

    try {
        Import-Module -Name $module -ErrorAction Stop
    }
    catch {
        Write-Result -Success $false -Message "No se pudo importar el módulo '$module': $($_.Exception.Message)"
    }
}

# ─────────────────────────────────────────────
# 2. AUTENTICACIÓN (Client Credentials)
# ─────────────────────────────────────────────

try {
    $secureSecret = ConvertTo-SecureString -String $ClientSecret -AsPlainText -Force
    $credential   = New-Object System.Management.Automation.PSCredential($ClientId, $secureSecret)

    Connect-MgGraph -TenantId $TenantId -ClientSecretCredential $credential -NoWelcome -ErrorAction Stop
}
catch {
    Write-Result -Success $false -Message "Error de autenticación contra Microsoft Graph: $($_.Exception.Message)"
}

# ─────────────────────────────────────────────
# 3. VALIDAR QUE EL SERVICE PRINCIPAL EXISTE
# ─────────────────────────────────────────────

try {
    $sp = Get-MgServicePrincipal -ServicePrincipalId $ServicePrincipalId -ErrorAction Stop
}
catch {
    Write-Result -Success $false -Message "No se encontró la enterprise app con ObjectId '$ServicePrincipalId': $($_.Exception.Message)"
}

# ─────────────────────────────────────────────
# 4. DETERMINAR TIPO DE PRINCIPAL
# ─────────────────────────────────────────────

try {
    $principalType = Get-PrincipalType -ObjectId $PrincipalId
}
catch {
    Write-Result -Success $false -Message $_.Exception.Message
}

# ─────────────────────────────────────────────
# 5. EJECUTAR ACCIÓN
# ─────────────────────────────────────────────

try {
    switch ($Action) {

        "Add" {
            # Idempotencia: comprobar si ya existe la asignación antes de crearla
            $existing = Get-ExistingAssignment -SpId $ServicePrincipalId -PrinId $PrincipalId -RoleId $AppRoleId

            if ($existing) {
                Write-Result -Success $true -Message "La asignación ya existía. No se realizó ningún cambio." -Data @{
                    assignmentId  = $existing.Id
                    principalId   = $PrincipalId
                    principalType = $principalType
                    appRoleId     = $AppRoleId
                    enterpriseApp = $sp.DisplayName
                }
            }

            $params = @{
                PrincipalId = $PrincipalId
                ResourceId  = $ServicePrincipalId
                AppRoleId   = $AppRoleId
            }

            $assignment = New-MgServicePrincipalAppRoleAssignedTo `
                -ServicePrincipalId $ServicePrincipalId `
                -BodyParameter $params `
                -ErrorAction Stop

            Write-Result -Success $true -Message "Asignación creada correctamente." -Data @{
                assignmentId  = $assignment.Id
                principalId   = $PrincipalId
                principalType = $principalType
                appRoleId     = $AppRoleId
                enterpriseApp = $sp.DisplayName
            }
        }

        "Remove" {
            # Buscar la asignación existente para obtener su ID
            $existing = Get-ExistingAssignment -SpId $ServicePrincipalId -PrinId $PrincipalId -RoleId $AppRoleId

            if (-not $existing) {
                Write-Result -Success $true -Message "La asignación no existía. No se realizó ningún cambio." -Data @{
                    principalId   = $PrincipalId
                    principalType = $principalType
                    appRoleId     = $AppRoleId
                    enterpriseApp = $sp.DisplayName
                }
            }

            Remove-MgServicePrincipalAppRoleAssignedTo `
                -ServicePrincipalId $ServicePrincipalId `
                -AppRoleAssignmentId $existing.Id `
                -ErrorAction Stop

            Write-Result -Success $true -Message "Asignación eliminada correctamente." -Data @{
                assignmentId  = $existing.Id
                principalId   = $PrincipalId
                principalType = $principalType
                appRoleId     = $AppRoleId
                enterpriseApp = $sp.DisplayName
            }
        }
    }
}
catch {
    Write-Result -Success $false -Message "Error al ejecutar la acción '$Action': $($_.Exception.Message)"
}
finally {
    # Desconectar sesión Graph al finalizar
    Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
}
