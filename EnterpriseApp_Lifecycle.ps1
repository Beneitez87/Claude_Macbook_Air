<#
.SYNOPSIS
    Gestión del ciclo de vida de Enterprise Apps (Entra ID) — script unificado.
    Fusiona las antiguas Fase 1 (asignaciones) y Fase 2 (creación).

    Operaciones (-Operation):
      Create : crea una app registration + service principal con configuración
               completa (propietarios, permisos API con admin consent, secreto,
               certificado y SSO SAML/OIDC).
      Add    : asigna un usuario o grupo a una enterprise app existente.
      Remove : elimina la asignación de un usuario o grupo.

.DESCRIPTION
    Microsoft Graph (SDK Microsoft.Graph) con autenticación client credentials
    (client_id + secret). Diseñado para invocarse desde ServiceNow (MID Server o
    REST step). Devuelve un único JSON estructurado con el resultado
    (success / message / timestamp / data); código de salida 0 (éxito) o 1 (error).

    Robustez frente a la latencia de replicación de Entra: TODAS las mutaciones
    posteriores a la creación (SP, propietarios, permisos, secreto, certificado y
    SSO) se reintentan con backoff (Invoke-WithRetry), reconociendo las firmas de
    error transitorias observadas en pruebas reales.

    La generación del certificado usa .NET CertificateRequest (disponible en
    .NET Framework 4.7.2+ y .NET Core), por lo que funciona en Windows PowerShell
    5.1 (Windows Server 2022, de fábrica) y en PowerShell 7 (Windows/macOS).

.PARAMETER Operation
    Operación a realizar: "Create", "Add" o "Remove".

.PARAMETER TenantId
    ID del tenant de Entra ID. (todas las operaciones)

.PARAMETER ClientId
    App ID (client_id) de la enterprise app ejecutora. (todas)

.PARAMETER ClientSecret
    Secret de la enterprise app ejecutora. (todas)

.PARAMETER DisplayName
    [Create] Nombre de la aplicación a crear.

.PARAMETER SignInAudience
    [Create] AzureADMyOrg (single-tenant, por defecto) o AzureADMultipleOrgs.

.PARAMETER Owners
    [Create] UPN(s) u ObjectId(s) de los propietarios técnicos.

.PARAMETER SsoType
    [Create] Tipo de SSO: "saml", "oidc" o "none" (por defecto).

.PARAMETER ReplyUrls
    [Create] URLs de respuesta/callback. ACS en SAML, redirect URI en OIDC.

.PARAMETER IdentifierUri
    [Create] Entity ID / Identifier URI (requerido para SAML). Entra exige un
    dominio verificado del tenant o el formato api://{appId}. Admite el token
    {appId}, que se sustituye por el App ID generado (p.ej. "api://{appId}").

.PARAMETER SignOnUrl
    [Create] (Solo SAML) URL de inicio de sesión (Sign-on URL); se fija en
    loginUrl del service principal.

.PARAMETER ApiPermissionsJson
    [Create] Cadena JSON con los permisos API a declarar y consentir. Formato:
    [
      {
        "resourceAppId": "00000003-0000-0000-c000-000000000000",
        "delegated":   ["User.Read", "Mail.Read"],
        "application": ["User.Read.All"]
      }
    ]
    Los nombres de permiso se resuelven automáticamente a sus IDs.

.PARAMETER RequireAssignment
    [Create] Si la enterprise app requiere asignación explícita (por defecto $true).

.PARAMETER GenerateSecret
    [Create] Boolean: generar un client secret y devolverlo en la salida.

.PARAMETER SecretDescription
    [Create] Descripción del secreto (ej: "ServiceNow-PRD").

.PARAMETER SecretExpiryMonths
    [Create] Duración del secreto en meses (por defecto 24).

.PARAMETER GenerateCert
    [Create] Boolean: generar un certificado autofirmado, subirlo y devolver
    el .cer y .pfx (base64) en la salida.

.PARAMETER CertValidityYears
    [Create] Validez del certificado en años (por defecto 2, equivalente a 24 meses).

.PARAMETER CertSubject
    [Create] Subject del certificado (por defecto "CN=<DisplayName>").

.PARAMETER NotificationEmail
    [Create] Correo del peticionario. En esta versión solo se registra para trazabilidad.

.PARAMETER AllowDuplicateName
    [Create] Permite crear la app aunque ya exista otra con el mismo DisplayName.

.PARAMETER ServicePrincipalId
    [Add/Remove] ObjectId del service principal (enterprise app) sobre el que operar.

.PARAMETER PrincipalId
    [Add/Remove] ObjectId del usuario o grupo a asignar o desasignar.

.PARAMETER AppRoleId
    [Add/Remove] (Opcional) App role a asignar; por defecto el rol de acceso por
    defecto (00000000-0000-0000-0000-000000000000).

.EXAMPLE
    # Crear una app sencilla con secreto, sin SSO ni permisos
    .\EnterpriseApp_Lifecycle.ps1 -Operation Create -TenantId <guid> -ClientId <guid> `
        -ClientSecret <secret> -DisplayName "Mi App" -GenerateSecret $true

.EXAMPLE
    # Asignar un usuario o grupo a una enterprise app existente
    .\EnterpriseApp_Lifecycle.ps1 -Operation Add -TenantId <guid> -ClientId <guid> `
        -ClientSecret <secret> -ServicePrincipalId <spId> -PrincipalId <userOrGroupId>

.NOTES
    Requiere Windows PowerShell 5.1+ o PowerShell 7+ (compatible de fábrica con
    Windows Server 2022).
    Módulos requeridos por operación:
        Create        : Microsoft.Graph.Authentication, .Applications, .Users, .Identity.SignIns
        Add / Remove  : Microsoft.Graph.Authentication, .Applications, .DirectoryObjects

    Permisos Graph (tipo Application) del ejecutor, por operación:
        Create        : Application.ReadWrite.All, AppRoleAssignment.ReadWrite.All,
                        DelegatedPermissionGrant.ReadWrite.All, Directory.Read.All
        Add / Remove  : AppRoleAssignment.ReadWrite.All, Application.Read.All, Directory.Read.All

    Un único ejecutor con el set de Create cubre todas las operaciones
    (Application.ReadWrite.All es superconjunto de Application.Read.All).
    Todos los permisos requieren consentimiento de administrador.
#>

#Requires -Version 5.1

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingConvertToSecureStringWithPlainText', '',
    Justification = 'Conversión inevitable: el client secret (flujo client-credentials) y la contraseña aleatoria del .pfx generado deben pasarse como SecureString a las APIs correspondientes. No se persisten en claro.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '',
    Justification = 'Write-Host solo se usa para mensajes de diagnóstico durante la instalación de módulos en primer arranque; el resultado de la operación se emite siempre por Write-Output en formato JSON.')]
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [ValidateSet("Create", "Add", "Remove")] [string] $Operation,

    [Parameter(Mandatory)] [string] $TenantId,
    [Parameter(Mandatory)] [string] $ClientId,
    [Parameter(Mandatory)] [string] $ClientSecret,

    # ── Create ─────────────────────────────────────────────
    [string] $DisplayName,

    [ValidateSet("AzureADMyOrg", "AzureADMultipleOrgs")]
    [string] $SignInAudience = "AzureADMyOrg",

    [string[]] $Owners = @(),

    [ValidateSet("saml", "oidc", "none")]
    [string] $SsoType = "none",

    [string[]] $ReplyUrls = @(),
    [string]   $IdentifierUri,
    [string]   $SignOnUrl,

    [string] $ApiPermissionsJson,

    [bool] $RequireAssignment = $true,

    [bool]   $GenerateSecret = $false,
    [string] $SecretDescription = "ServiceNow",
    [int]    $SecretExpiryMonths = 24,

    [bool]   $GenerateCert = $false,
    [int]    $CertValidityYears = 2,   # 2 años = 24 meses (vigencia estándar)
    [string] $CertSubject,

    [string] $NotificationEmail,

    [switch] $AllowDuplicateName,

    # ── Add / Remove ───────────────────────────────────────
    [string] $ServicePrincipalId,
    [string] $PrincipalId,
    [string] $AppRoleId = "00000000-0000-0000-0000-000000000000"
)

$ErrorActionPreference = "Stop"

# ─────────────────────────────────────────────
# FUNCIONES AUXILIARES (comunes)
# ─────────────────────────────────────────────

function Write-Result {
    <#
    .SYNOPSIS
        Escribe el resultado final en JSON y termina el script. ServiceNow parsea
        este JSON para determinar éxito o error.
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
    Write-Output ($result | ConvertTo-Json -Depth 10 -Compress)
    exit $(if ($Success) { 0 } else { 1 })
}

function Test-IsGuid {
    <#
    .SYNOPSIS
        Valida que una cadena tenga formato GUID.
    #>
    param([string] $Value)
    [guid]::TryParse($Value, [ref]([guid]::Empty))
}

function Invoke-WithRetry {
    <#
    .SYNOPSIS
        Reintenta un bloque ante errores transitorios de replicación de Entra:
        tras crear la app/SP, los objetos tardan unos segundos en ser visibles en
        todos los nodos de Graph, provocando errores intermitentes al asignar
        owners, permisos, secreto, certificado o SSO. Las firmas de error
        reconocidas proceden de pruebas reales en tenant.
    #>
    param(
        [Parameter(Mandatory)] [scriptblock] $Script,
        [int] $MaxAttempts  = 5,
        [int] $DelaySeconds = 4
    )
    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        try {
            return & $Script
        }
        catch {
            $transient = $_.Exception.Message -match 'does not exist|does not reference a valid|ResourceNotFound|ObjectNotFound|Request_ResourceNotFound|not found|replicat|directoryObject|company information'
            if ($attempt -ge $MaxAttempts -or -not $transient) { throw }
            Start-Sleep -Seconds ($DelaySeconds * $attempt)
        }
    }
}

# ─────────────────────────────────────────────
# FUNCIONES AUXILIARES (Add / Remove)
# ─────────────────────────────────────────────

function Get-PrincipalType {
    <#
    .SYNOPSIS
        Determina si un ObjectId corresponde a un usuario, grupo o service
        principal. Lanza excepción si no se encuentra o el tipo no está soportado.
    #>
    param([string] $ObjectId)

    $dirObject = Get-MgDirectoryObject -DirectoryObjectId $ObjectId -ErrorAction SilentlyContinue

    if (-not $dirObject) {
        throw "No se encontró ningún objeto de directorio con ObjectId: $ObjectId"
    }

    # El SDK expone el tipo derivado en AdditionalProperties['@odata.type'];
    # la propiedad fuerte .ODataType suele venir vacía.
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
# FUNCIONES AUXILIARES (Create)
# ─────────────────────────────────────────────

function Resolve-PrincipalObjectId {
    <#
    .SYNOPSIS
        Acepta un UPN o un ObjectId y devuelve siempre el ObjectId del usuario.
    #>
    param([string] $UserRef)

    if (Test-IsGuid -Value $UserRef) {
        return $UserRef
    }

    $user = Get-MgUser -UserId $UserRef -Property Id -ErrorAction SilentlyContinue
    if (-not $user) {
        throw "No se pudo resolver el propietario '$UserRef' (ni GUID ni UPN válido en el tenant)."
    }
    return $user.Id
}

function Resolve-ResourceAccess {
    <#
    .SYNOPSIS
        A partir del bloque de permisos (resourceAppId + nombres delegados y de
        aplicación), resuelve los IDs reales consultando el service principal del
        recurso. Devuelve requiredResourceAccess, resourceSpId y las listas de
        scopes/roles resueltos para el consent.
    #>
    param([object] $PermissionBlock)

    $resourceAppId = $PermissionBlock.resourceAppId
    if (-not $resourceAppId) {
        throw "Cada bloque de apiPermissions debe incluir 'resourceAppId'."
    }

    $resourceFilter = "appId eq '" + ($resourceAppId -replace "'", "''") + "'"
    $resourceSp = Get-MgServicePrincipal -Filter $resourceFilter -ErrorAction Stop |
        Select-Object -First 1
    if (-not $resourceSp) {
        throw "No se encontró el service principal del recurso con appId '$resourceAppId'."
    }

    $resourceAccess = @()
    $resolvedScopes = @()
    $resolvedRoles  = @()

    foreach ($name in @($PermissionBlock.delegated)) {
        if (-not $name) { continue }
        $scope = $resourceSp.Oauth2PermissionScopes | Where-Object { $_.Value -eq $name } | Select-Object -First 1
        if (-not $scope) {
            throw "El permiso delegado '$name' no existe en el recurso '$resourceAppId'."
        }
        $resourceAccess += @{ id = $scope.Id; type = "Scope" }
        $resolvedScopes  += $name
    }

    foreach ($name in @($PermissionBlock.application)) {
        if (-not $name) { continue }
        $role = $resourceSp.AppRoles | Where-Object { $_.Value -eq $name } | Select-Object -First 1
        if (-not $role) {
            throw "El permiso de aplicación '$name' no existe en el recurso '$resourceAppId'."
        }
        $resourceAccess += @{ id = $role.Id; type = "Role" }
        $resolvedRoles  += @{ id = $role.Id; value = $name }
    }

    return [pscustomobject]@{
        ResourceSpId           = $resourceSp.Id
        ResourceAppId          = $resourceAppId
        RequiredResourceAccess = @{ resourceAppId = $resourceAppId; resourceAccess = $resourceAccess }
        DelegatedScopes        = $resolvedScopes
        ApplicationRoles       = $resolvedRoles
    }
}

# ─────────────────────────────────────────────
# 0. VALIDAR PARÁMETROS (según la operación)
# ─────────────────────────────────────────────

foreach ($p in @(
    @{ Name = "TenantId"; Value = $TenantId },
    @{ Name = "ClientId"; Value = $ClientId }
)) {
    if (-not (Test-IsGuid -Value $p.Value)) {
        Write-Result -Success $false -Message "El parámetro '$($p.Name)' no tiene un formato GUID válido: '$($p.Value)'."
    }
}

switch ($Operation) {
    "Create" {
        if ([string]::IsNullOrWhiteSpace($DisplayName)) {
            Write-Result -Success $false -Message "La operación 'Create' requiere -DisplayName."
        }
        if ($SsoType -eq "saml" -and [string]::IsNullOrWhiteSpace($IdentifierUri)) {
            Write-Result -Success $false -Message "SSO SAML requiere el parámetro -IdentifierUri (Entity ID)."
        }
        if ($SsoType -ne "none" -and $ReplyUrls.Count -eq 0) {
            Write-Result -Success $false -Message "SSO '$SsoType' requiere al menos una URL en -ReplyUrls."
        }
        if ($SignOnUrl -and $SsoType -ne "saml") {
            Write-Result -Success $false -Message "-SignOnUrl solo aplica a SSO SAML."
        }
        $apiPermissions = @()
        if (-not [string]::IsNullOrWhiteSpace($ApiPermissionsJson)) {
            try {
                $apiPermissions = @($ApiPermissionsJson | ConvertFrom-Json -ErrorAction Stop)
            }
            catch {
                Write-Result -Success $false -Message "ApiPermissionsJson no es un JSON válido: $($_.Exception.Message)"
            }
        }
    }
    default {
        # Add / Remove
        foreach ($p in @(
            @{ Name = "ServicePrincipalId"; Value = $ServicePrincipalId },
            @{ Name = "PrincipalId";        Value = $PrincipalId },
            @{ Name = "AppRoleId";          Value = $AppRoleId }
        )) {
            if (-not (Test-IsGuid -Value $p.Value)) {
                Write-Result -Success $false -Message "El parámetro '$($p.Name)' no tiene un formato GUID válido: '$($p.Value)'."
            }
        }
    }
}

# ─────────────────────────────────────────────
# 1. VERIFICAR, INSTALAR E IMPORTAR MÓDULOS
# ─────────────────────────────────────────────

$requiredModules = if ($Operation -eq "Create") {
    @("Microsoft.Graph.Authentication", "Microsoft.Graph.Applications",
      "Microsoft.Graph.Users", "Microsoft.Graph.Identity.SignIns")
}
else {
    @("Microsoft.Graph.Authentication", "Microsoft.Graph.Applications",
      "Microsoft.Graph.DirectoryObjects")
}

# Windows PowerShell 5.1 puede no negociar TLS 1.2 por defecto, requerido por
# PSGallery. En PowerShell 7 es inocuo.
try {
    [Net.ServicePointManager]::SecurityProtocol =
        [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
}
catch {
    Write-Verbose "No se pudo ajustar TLS 1.2: $($_.Exception.Message)"
}

foreach ($module in $requiredModules) {
    if (-not (Get-Module -ListAvailable -Name $module)) {
        Write-Host "Módulo '$module' no encontrado. Instalando..." -ForegroundColor Yellow
        try {
            if (-not (Get-PackageProvider -Name NuGet -ListAvailable -ErrorAction SilentlyContinue)) {
                Install-PackageProvider -Name NuGet -Scope CurrentUser -Force -ErrorAction Stop | Out-Null
            }
            $gallery = Get-PSRepository -Name PSGallery -ErrorAction SilentlyContinue
            if ($gallery -and $gallery.InstallationPolicy -ne 'Trusted') {
                Set-PSRepository -Name PSGallery -InstallationPolicy Trusted -ErrorAction SilentlyContinue
            }
            Install-Module -Name $module -Scope CurrentUser -Force -AllowClobber -ErrorAction Stop
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
# 3. EJECUTAR LA OPERACIÓN
# ─────────────────────────────────────────────

try {
    switch ($Operation) {

        # ═════════════════════════════════════════
        # CREATE  (antigua Fase 2)
        # ═════════════════════════════════════════
        "Create" {
            $out = [ordered]@{
                operation           = "Create"
                applicationObjectId = $null
                appId               = $null
                servicePrincipalId  = $null
                displayName         = $DisplayName
                owners              = @()
                apiPermissions      = @()
                secret              = $null
                certificate         = $null
                sso                 = $null
                notificationEmail   = $NotificationEmail
            }

            try {
                # ── Guarda de duplicados ──
                if (-not $AllowDuplicateName) {
                    $dupeFilter = "displayName eq '" + ($DisplayName -replace "'", "''") + "'"
                    $dupe = Get-MgApplication -Filter $dupeFilter -ErrorAction SilentlyContinue |
                        Select-Object -First 1
                    if ($dupe) {
                        Write-Result -Success $false -Message "Ya existe una aplicación con displayName '$DisplayName' (AppId $($dupe.AppId)). Usa -AllowDuplicateName para forzar." -Data $out
                    }
                }

                # ── Crear app registration ──
                $appParams = @{
                    DisplayName    = $DisplayName
                    SignInAudience = $SignInAudience
                }
                if ($ReplyUrls.Count -gt 0) {
                    $appParams.Web = @{ RedirectUris = $ReplyUrls }
                }
                $app = New-MgApplication @appParams -ErrorAction Stop
                $out.applicationObjectId = $app.Id
                $out.appId               = $app.AppId

                # ── Crear service principal (enterprise app) ──
                $spBody = @{
                    appId                     = $app.AppId
                    appRoleAssignmentRequired = $RequireAssignment
                }
                $sp = Invoke-WithRetry -Script {
                    New-MgServicePrincipal -BodyParameter $spBody -ErrorAction Stop
                }
                $out.servicePrincipalId = $sp.Id

                # ── Propietarios ──
                foreach ($ownerRef in $Owners) {
                    $ownerId = Resolve-PrincipalObjectId -UserRef $ownerRef
                    Invoke-WithRetry -Script {
                        New-MgApplicationOwnerByRef -ApplicationId $app.Id -BodyParameter @{
                            "@odata.id" = "https://graph.microsoft.com/v1.0/directoryObjects/$ownerId"
                        } -ErrorAction Stop
                    }
                    $out.owners += $ownerId
                }

                # ── Permisos API + admin consent ──
                if ($apiPermissions.Count -gt 0) {
                    $requiredResourceAccess = @()
                    $resolvedBlocks         = @()

                    foreach ($block in $apiPermissions) {
                        $resolved = Resolve-ResourceAccess -PermissionBlock $block
                        $requiredResourceAccess += $resolved.RequiredResourceAccess
                        $resolvedBlocks         += $resolved
                    }

                    Invoke-WithRetry -Script {
                        Update-MgApplication -ApplicationId $app.Id -RequiredResourceAccess $requiredResourceAccess -ErrorAction Stop
                    }

                    foreach ($resolved in $resolvedBlocks) {
                        if ($resolved.DelegatedScopes.Count -gt 0) {
                            Invoke-WithRetry -Script {
                                New-MgOauth2PermissionGrant -BodyParameter @{
                                    clientId    = $sp.Id
                                    consentType = "AllPrincipals"
                                    resourceId  = $resolved.ResourceSpId
                                    scope       = ($resolved.DelegatedScopes -join " ")
                                } -ErrorAction Stop | Out-Null
                            }
                        }
                        foreach ($role in $resolved.ApplicationRoles) {
                            Invoke-WithRetry -Script {
                                New-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $sp.Id -BodyParameter @{
                                    principalId = $sp.Id
                                    resourceId  = $resolved.ResourceSpId
                                    appRoleId   = $role.id
                                } -ErrorAction Stop | Out-Null
                            }
                        }

                        $out.apiPermissions += [ordered]@{
                            resourceAppId = $resolved.ResourceAppId
                            delegated     = $resolved.DelegatedScopes
                            application   = @($resolved.ApplicationRoles.value)
                        }
                    }
                }

                # ── Secreto ──
                if ($GenerateSecret) {
                    $passwordCred = @{
                        displayName = $SecretDescription
                        endDateTime = ([DateTime]::UtcNow.AddMonths($SecretExpiryMonths))
                    }
                    $secret = Invoke-WithRetry -Script {
                        Add-MgApplicationPassword -ApplicationId $app.Id -PasswordCredential $passwordCred -ErrorAction Stop
                    }
                    $out.secret = [ordered]@{
                        keyId       = $secret.KeyId
                        value       = $secret.SecretText   # solo disponible ahora; entregar y descartar
                        description = $SecretDescription
                        endDateTime = $secret.EndDateTime
                    }
                }

                # ── Certificado (multiplataforma, .NET) ──
                if ($GenerateCert) {
                    $subject = if ($CertSubject) { $CertSubject } else { "CN=$DisplayName" }

                    $rsa = [System.Security.Cryptography.RSA]::Create(2048)
                    $req = [System.Security.Cryptography.X509Certificates.CertificateRequest]::new(
                        $subject,
                        $rsa,
                        [System.Security.Cryptography.HashAlgorithmName]::SHA256,
                        [System.Security.Cryptography.RSASignaturePadding]::Pkcs1
                    )
                    $notBefore = [DateTimeOffset]::UtcNow.AddDays(-1)
                    $notAfter  = [DateTimeOffset]::UtcNow.AddYears($CertValidityYears)
                    $cert = $req.CreateSelfSigned($notBefore, $notAfter)

                    $cerBytes = $cert.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Cert)

                    # RandomNumberGenerator.GetBytes(int) estático es .NET Core+;
                    # la forma de instancia funciona también en Windows PowerShell 5.1.
                    $rngBytes = [byte[]]::new(24)
                    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
                    try { $rng.GetBytes($rngBytes) } finally { $rng.Dispose() }
                    $pfxPassword = [System.Convert]::ToBase64String($rngBytes)
                    $pfxSecure   = ConvertTo-SecureString -String $pfxPassword -AsPlainText -Force
                    $pfxBytes    = $cert.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Pfx, $pfxSecure)

                    Invoke-WithRetry -Script {
                        Update-MgApplication -ApplicationId $app.Id -KeyCredentials @(@{
                            type        = "AsymmetricX509Cert"
                            usage       = "Verify"
                            key         = $cerBytes
                            displayName = $subject
                        }) -ErrorAction Stop
                    }

                    $out.certificate = [ordered]@{
                        thumbprint  = $cert.Thumbprint
                        subject     = $subject
                        notAfter    = $notAfter.UtcDateTime.ToString("yyyy-MM-ddTHH:mm:ssZ")
                        cerBase64   = [Convert]::ToBase64String($cerBytes)
                        pfxBase64   = [Convert]::ToBase64String($pfxBytes)
                        pfxPassword = $pfxPassword
                    }
                }

                # ── SSO ──
                switch ($SsoType) {
                    "saml" {
                        # El Entity ID admite el token {appId}, que se sustituye por
                        # el App ID generado. Entra exige identifierUris con dominio
                        # verificado o el formato api://{appId}.
                        $effIdUri = $IdentifierUri -replace '\{appId\}', $app.AppId
                        Invoke-WithRetry -Script {
                            Update-MgApplication -ApplicationId $app.Id `
                                -IdentifierUris @($effIdUri) `
                                -Web @{ RedirectUris = $ReplyUrls } -ErrorAction Stop
                        }

                        $spSamlParams = @{
                            ServicePrincipalId        = $sp.Id
                            PreferredSingleSignOnMode = "saml"
                            ReplyUrls                 = $ReplyUrls
                        }
                        if ($SignOnUrl) { $spSamlParams.LoginUrl = $SignOnUrl }
                        Invoke-WithRetry -Script {
                            Update-MgServicePrincipal @spSamlParams -ErrorAction Stop
                        }

                        $metaUrl = "https://login.microsoftonline.com/$TenantId/federationmetadata/2007-06/federationmetadata.xml?appid=$($app.AppId)"
                        $metadataXml = $null
                        try {
                            $metadataXml = (Invoke-WebRequest -Uri $metaUrl -UseBasicParsing -ErrorAction Stop).Content
                        }
                        catch {
                            $metadataXml = "PENDIENTE: los metadatos aún no están disponibles. URL: $metaUrl"
                        }

                        $out.sso = [ordered]@{
                            type          = "saml"
                            identifierUri = $effIdUri
                            signOnUrl     = $SignOnUrl
                            replyUrls     = $ReplyUrls
                            metadataUrl   = $metaUrl
                            metadataXml   = $metadataXml
                        }
                    }
                    "oidc" {
                        Invoke-WithRetry -Script {
                            Update-MgApplication -ApplicationId $app.Id -Web @{
                                RedirectUris          = $ReplyUrls
                                ImplicitGrantSettings = @{ EnableIdTokenIssuance = $true }
                            } -ErrorAction Stop
                        }
                        $out.sso = [ordered]@{
                            type         = "oidc"
                            redirectUris = $ReplyUrls
                            authority    = "https://login.microsoftonline.com/$TenantId/v2.0"
                        }
                    }
                    "none" {
                        $out.sso = [ordered]@{ type = "none" }
                    }
                }

                Write-Result -Success $true -Message "Enterprise app '$DisplayName' creada correctamente." -Data $out
            }
            catch {
                Write-Result -Success $false -Message "Error durante la creación: $($_.Exception.Message)" -Data $out
            }
        }

        # ═════════════════════════════════════════
        # ADD / REMOVE  (antigua Fase 1)
        # ═════════════════════════════════════════
        default {
            # Validar que el service principal existe
            try {
                $sp = Get-MgServicePrincipal -ServicePrincipalId $ServicePrincipalId -ErrorAction Stop
            }
            catch {
                Write-Result -Success $false -Message "No se encontró la enterprise app con ObjectId '$ServicePrincipalId': $($_.Exception.Message)"
            }

            # Determinar el tipo de principal
            try {
                $principalType = Get-PrincipalType -ObjectId $PrincipalId
            }
            catch {
                Write-Result -Success $false -Message $_.Exception.Message
            }

            if ($Operation -eq "Add") {
                $existing = Get-ExistingAssignment -SpId $ServicePrincipalId -PrinId $PrincipalId -RoleId $AppRoleId
                if ($existing) {
                    Write-Result -Success $true -Message "La asignación ya existía. No se realizó ningún cambio." -Data @{
                        operation     = "Add"
                        assignmentId  = $existing.Id
                        principalId   = $PrincipalId
                        principalType = $principalType
                        appRoleId     = $AppRoleId
                        enterpriseApp = $sp.DisplayName
                    }
                }

                $assignment = New-MgServicePrincipalAppRoleAssignedTo `
                    -ServicePrincipalId $ServicePrincipalId `
                    -BodyParameter @{
                        PrincipalId = $PrincipalId
                        ResourceId  = $ServicePrincipalId
                        AppRoleId   = $AppRoleId
                    } -ErrorAction Stop

                Write-Result -Success $true -Message "Asignación creada correctamente." -Data @{
                    operation     = "Add"
                    assignmentId  = $assignment.Id
                    principalId   = $PrincipalId
                    principalType = $principalType
                    appRoleId     = $AppRoleId
                    enterpriseApp = $sp.DisplayName
                }
            }
            else {
                # Remove
                $existing = Get-ExistingAssignment -SpId $ServicePrincipalId -PrinId $PrincipalId -RoleId $AppRoleId
                if (-not $existing) {
                    Write-Result -Success $true -Message "La asignación no existía. No se realizó ningún cambio." -Data @{
                        operation     = "Remove"
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
                    operation     = "Remove"
                    assignmentId  = $existing.Id
                    principalId   = $PrincipalId
                    principalType = $principalType
                    appRoleId     = $AppRoleId
                    enterpriseApp = $sp.DisplayName
                }
            }
        }
    }
}
catch {
    Write-Result -Success $false -Message "Error al ejecutar la operación '$Operation': $($_.Exception.Message)"
}
finally {
    Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
}
