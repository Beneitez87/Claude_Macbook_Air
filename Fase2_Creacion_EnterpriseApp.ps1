<#
.SYNOPSIS
    Fase 2 - Creación de Enterprise Apps (Entra ID)
    Crea una app registration + service principal con configuración completa:
    propietarios, permisos API (con admin consent), secreto, certificado y SSO
    (SAML u OIDC).

.DESCRIPTION
    Utiliza Microsoft Graph (vía SDK Microsoft.Graph) con autenticación
    client credentials (client_id + secret). Diseñado para ser invocado desde
    ServiceNow (MID Server o REST step).

    Devuelve un JSON estructurado con el resultado. En esta versión NO envía
    correos: el secreto, el certificado (.cer y .pfx en base64) y el XML de
    metadatos SAML se devuelven dentro del JSON de salida para que el
    orquestador los gestione. El envío por email se implementará como módulo
    aparte.

    La generación del certificado es MULTIPLATAFORMA (.NET CertificateRequest),
    por lo que funciona en PowerShell Core sobre macOS y Windows.

.PARAMETER TenantId
    ID del tenant de Entra ID.

.PARAMETER ClientId
    App ID (client_id) de la enterprise app ejecutora.

.PARAMETER ClientSecret
    Secret de la enterprise app ejecutora.

.PARAMETER DisplayName
    Nombre de la aplicación a crear.

.PARAMETER SignInAudience
    AzureADMyOrg (single-tenant, por defecto) o AzureADMultipleOrgs.

.PARAMETER Owners
    UPN(s) u ObjectId(s) de los propietarios técnicos. Se resuelven a object id.

.PARAMETER SsoType
    Tipo de SSO: "saml", "oidc" o "none" (por defecto).

.PARAMETER ReplyUrls
    URLs de respuesta/callback. ACS en SAML, redirect URI en OIDC.

.PARAMETER IdentifierUri
    Entity ID / Identifier URI (requerido para SAML).

.PARAMETER ApiPermissionsJson
    Cadena JSON con los permisos API a declarar y consentir. Formato:
    [
      {
        "resourceAppId": "00000003-0000-0000-c000-000000000000",
        "delegated":   ["User.Read", "Mail.Read"],
        "application": ["User.Read.All"]
      }
    ]
    Los nombres de permiso se resuelven automáticamente a sus IDs.

.PARAMETER RequireAssignment
    Si la enterprise app requiere asignación explícita de usuario (por defecto $true).

.PARAMETER GenerateSecret
    Boolean: generar un client secret y devolverlo en la salida.

.PARAMETER SecretDescription
    Descripción del secreto (ej: "ServiceNow-PRD").

.PARAMETER SecretExpiryMonths
    Duración del secreto en meses (por defecto 24, vigencia estándar).

.PARAMETER GenerateCert
    Boolean: generar un certificado autofirmado, subirlo a la app y devolver
    el .cer y .pfx (base64) en la salida.

.PARAMETER CertValidityYears
    Validez del certificado en años (por defecto 2, equivalente a 24 meses).

.PARAMETER CertSubject
    Subject del certificado (por defecto "CN=<DisplayName>").

.PARAMETER NotificationEmail
    Correo del peticionario. En esta versión solo se registra para trazabilidad.

.PARAMETER AllowDuplicateName
    Si se indica, permite crear la app aunque ya exista otra con el mismo
    DisplayName. Por defecto el script falla si detecta un duplicado.

.NOTES
    Módulos requeridos: Microsoft.Graph.Authentication, Microsoft.Graph.Applications,
                        Microsoft.Graph.Users, Microsoft.Graph.Identity.SignIns
    Permisos Graph (Application) del ejecutor:
        Application.ReadWrite.All, AppRoleAssignment.ReadWrite.All,
        DelegatedPermissionGrant.ReadWrite.All, Directory.Read.All
#>

#Requires -Version 7.0

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingConvertToSecureStringWithPlainText', '',
    Justification = 'Conversión inevitable: el client secret (flujo client-credentials) y la contraseña aleatoria del .pfx generado deben pasarse como SecureString a las APIs correspondientes. No se persisten en claro.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '',
    Justification = 'Write-Host solo se usa para mensajes de diagnóstico durante la instalación de módulos en primer arranque; el resultado de la operación se emite siempre por Write-Output en formato JSON.')]
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $TenantId,
    [Parameter(Mandatory)] [string] $ClientId,
    [Parameter(Mandatory)] [string] $ClientSecret,

    [Parameter(Mandatory)] [string] $DisplayName,

    [ValidateSet("AzureADMyOrg", "AzureADMultipleOrgs")]
    [string] $SignInAudience = "AzureADMyOrg",

    [string[]] $Owners = @(),

    [ValidateSet("saml", "oidc", "none")]
    [string] $SsoType = "none",

    [string[]] $ReplyUrls = @(),
    [string]   $IdentifierUri,

    [string] $ApiPermissionsJson,

    [bool] $RequireAssignment = $true,

    [bool]   $GenerateSecret = $false,
    [string] $SecretDescription = "ServiceNow",
    [int]    $SecretExpiryMonths = 24,

    [bool]   $GenerateCert = $false,
    [int]    $CertValidityYears = 2,   # 2 años = 24 meses (vigencia estándar)
    [string] $CertSubject,

    [string] $NotificationEmail,

    [switch] $AllowDuplicateName
)

$ErrorActionPreference = "Stop"

# ─────────────────────────────────────────────
# FUNCIONES AUXILIARES
# ─────────────────────────────────────────────

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
    Write-Output ($result | ConvertTo-Json -Depth 10 -Compress)
    exit $(if ($Success) { 0 } else { 1 })
}

function Test-IsGuid {
    param([string] $Value)
    [guid]::TryParse($Value, [ref]([guid]::Empty))
}

function Resolve-PrincipalObjectId {
    <#
    .SYNOPSIS
        Acepta un UPN o un ObjectId y devuelve siempre el ObjectId del usuario.
        Si ya es un GUID se devuelve tal cual; si es un UPN se resuelve vía Graph.
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
        aplicación), resuelve los IDs reales consultando el service principal
        del recurso. Devuelve un objeto con: requiredResourceAccess (para la app),
        resourceSpId, y las listas de scopes/roles resueltos para el consent.
    #>
    param([object] $PermissionBlock)

    $resourceAppId = $PermissionBlock.resourceAppId
    if (-not $resourceAppId) {
        throw "Cada bloque de apiPermissions debe incluir 'resourceAppId'."
    }

    $resourceSp = Get-MgServicePrincipal -Filter "appId eq '$resourceAppId'" -ErrorAction Stop |
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
        ResourceSpId          = $resourceSp.Id
        ResourceAppId         = $resourceAppId
        RequiredResourceAccess = @{ resourceAppId = $resourceAppId; resourceAccess = $resourceAccess }
        DelegatedScopes       = $resolvedScopes
        ApplicationRoles      = $resolvedRoles
    }
}

# ─────────────────────────────────────────────
# 0. VALIDAR PARÁMETROS
# ─────────────────────────────────────────────

foreach ($p in @(
    @{ Name = "TenantId"; Value = $TenantId },
    @{ Name = "ClientId"; Value = $ClientId }
)) {
    if (-not (Test-IsGuid -Value $p.Value)) {
        Write-Result -Success $false -Message "El parámetro '$($p.Name)' no tiene un formato GUID válido: '$($p.Value)'."
    }
}

if ($SsoType -eq "saml" -and [string]::IsNullOrWhiteSpace($IdentifierUri)) {
    Write-Result -Success $false -Message "SSO SAML requiere el parámetro -IdentifierUri (Entity ID)."
}
if ($SsoType -ne "none" -and $ReplyUrls.Count -eq 0) {
    Write-Result -Success $false -Message "SSO '$SsoType' requiere al menos una URL en -ReplyUrls."
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

# ─────────────────────────────────────────────
# 1. VERIFICAR, INSTALAR E IMPORTAR MÓDULOS
# ─────────────────────────────────────────────

$requiredModules = @(
    "Microsoft.Graph.Authentication",
    "Microsoft.Graph.Applications",
    "Microsoft.Graph.Users",
    "Microsoft.Graph.Identity.SignIns"
)

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

# Acumulador de resultados. Se va rellenando paso a paso para poder informar
# de lo ya creado aunque un paso posterior falle (evita huérfanos silenciosos).
$out = [ordered]@{
    applicationObjectId  = $null
    appId                = $null
    servicePrincipalId   = $null
    displayName          = $DisplayName
    owners               = @()
    apiPermissions       = @()
    secret               = $null
    certificate          = $null
    sso                  = $null
    notificationEmail    = $NotificationEmail
}

try {
    # ─────────────────────────────────────────────
    # 3. GUARDA DE DUPLICADOS
    # ─────────────────────────────────────────────
    if (-not $AllowDuplicateName) {
        $dupe = Get-MgApplication -Filter "displayName eq '$DisplayName'" -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($dupe) {
            Write-Result -Success $false -Message "Ya existe una aplicación con displayName '$DisplayName' (AppId $($dupe.AppId)). Usa -AllowDuplicateName para forzar."
        }
    }

    # ─────────────────────────────────────────────
    # 4. CREAR APP REGISTRATION
    # ─────────────────────────────────────────────
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

    # ─────────────────────────────────────────────
    # 5. CREAR SERVICE PRINCIPAL (ENTERPRISE APP)
    # ─────────────────────────────────────────────
    $sp = New-MgServicePrincipal -BodyParameter @{
        appId                    = $app.AppId
        appRoleAssignmentRequired = $RequireAssignment
    } -ErrorAction Stop
    $out.servicePrincipalId = $sp.Id

    # ─────────────────────────────────────────────
    # 6. PROPIETARIOS
    # ─────────────────────────────────────────────
    foreach ($ownerRef in $Owners) {
        $ownerId = Resolve-PrincipalObjectId -UserRef $ownerRef
        New-MgApplicationOwnerByRef -ApplicationId $app.Id -BodyParameter @{
            "@odata.id" = "https://graph.microsoft.com/v1.0/directoryObjects/$ownerId"
        } -ErrorAction Stop
        $out.owners += $ownerId
    }

    # ─────────────────────────────────────────────
    # 7. PERMISOS API + ADMIN CONSENT
    # ─────────────────────────────────────────────
    if ($apiPermissions.Count -gt 0) {
        $requiredResourceAccess = @()
        $resolvedBlocks         = @()

        foreach ($block in $apiPermissions) {
            $resolved = Resolve-ResourceAccess -PermissionBlock $block
            $requiredResourceAccess += $resolved.RequiredResourceAccess
            $resolvedBlocks         += $resolved
        }

        # Declarar los permisos en la app registration
        Update-MgApplication -ApplicationId $app.Id -RequiredResourceAccess $requiredResourceAccess -ErrorAction Stop

        # Conceder consent
        foreach ($resolved in $resolvedBlocks) {
            # Delegados -> oauth2PermissionGrant (AllPrincipals)
            if ($resolved.DelegatedScopes.Count -gt 0) {
                New-MgOauth2PermissionGrant -BodyParameter @{
                    clientId    = $sp.Id
                    consentType = "AllPrincipals"
                    resourceId  = $resolved.ResourceSpId
                    scope       = ($resolved.DelegatedScopes -join " ")
                } -ErrorAction Stop | Out-Null
            }
            # Aplicación -> appRoleAssignment por cada rol
            foreach ($role in $resolved.ApplicationRoles) {
                New-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $sp.Id -BodyParameter @{
                    principalId = $sp.Id
                    resourceId  = $resolved.ResourceSpId
                    appRoleId   = $role.id
                } -ErrorAction Stop | Out-Null
            }

            $out.apiPermissions += [ordered]@{
                resourceAppId = $resolved.ResourceAppId
                delegated     = $resolved.DelegatedScopes
                application   = @($resolved.ApplicationRoles.value)
            }
        }
    }

    # ─────────────────────────────────────────────
    # 8. SECRETO
    # ─────────────────────────────────────────────
    if ($GenerateSecret) {
        $passwordCred = @{
            displayName = $SecretDescription
            endDateTime = ([DateTime]::UtcNow.AddMonths($SecretExpiryMonths))
        }
        $secret = Add-MgApplicationPassword -ApplicationId $app.Id -PasswordCredential $passwordCred -ErrorAction Stop
        $out.secret = [ordered]@{
            keyId       = $secret.KeyId
            value       = $secret.SecretText   # solo disponible ahora; el orquestador debe enviarlo y descartarlo
            description = $SecretDescription
            endDateTime = $secret.EndDateTime
        }
    }

    # ─────────────────────────────────────────────
    # 9. CERTIFICADO (multiplataforma, .NET)
    # ─────────────────────────────────────────────
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

        # Contraseña aleatoria para el .pfx
        $pfxPassword = [System.Convert]::ToBase64String([System.Security.Cryptography.RandomNumberGenerator]::GetBytes(24))
        $pfxSecure   = ConvertTo-SecureString -String $pfxPassword -AsPlainText -Force
        $pfxBytes    = $cert.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Pfx, $pfxSecure)

        # Subir la clave pública a la app
        Update-MgApplication -ApplicationId $app.Id -KeyCredentials @(@{
            type        = "AsymmetricX509Cert"
            usage       = "Verify"
            key         = $cerBytes
            displayName = $subject
        }) -ErrorAction Stop

        $out.certificate = [ordered]@{
            thumbprint  = $cert.Thumbprint
            subject     = $subject
            notAfter    = $notAfter.UtcDateTime.ToString("yyyy-MM-ddTHH:mm:ssZ")
            cerBase64   = [Convert]::ToBase64String($cerBytes)   # clave pública (.cer) para el peticionario
            pfxBase64   = [Convert]::ToBase64String($pfxBytes)   # clave privada (.pfx) protegida por contraseña
            pfxPassword = $pfxPassword
        }
    }

    # ─────────────────────────────────────────────
    # 10. SSO
    # ─────────────────────────────────────────────
    switch ($SsoType) {
        "saml" {
            Update-MgApplication -ApplicationId $app.Id `
                -IdentifierUris @($IdentifierUri) `
                -Web @{ RedirectUris = $ReplyUrls } -ErrorAction Stop

            Update-MgServicePrincipal -ServicePrincipalId $sp.Id `
                -PreferredSingleSignOnMode "saml" `
                -ReplyUrls $ReplyUrls -ErrorAction Stop

            # Descargar el XML de metadatos de federación
            $metaUrl = "https://login.microsoftonline.com/$TenantId/federationmetadata/2007-06/federationmetadata.xml?appid=$($app.AppId)"
            $metadataXml = $null
            try {
                $metadataXml = (Invoke-WebRequest -Uri $metaUrl -UseBasicParsing -ErrorAction Stop).Content
            }
            catch {
                # Los metadatos pueden tardar unos segundos en estar disponibles tras la creación
                $metadataXml = "PENDIENTE: los metadatos aún no están disponibles. URL: $metaUrl"
            }

            $out.sso = [ordered]@{
                type          = "saml"
                identifierUri = $IdentifierUri
                replyUrls     = $ReplyUrls
                metadataUrl   = $metaUrl
                metadataXml   = $metadataXml
            }
        }
        "oidc" {
            Update-MgApplication -ApplicationId $app.Id -Web @{
                RedirectUris          = $ReplyUrls
                ImplicitGrantSettings = @{ EnableIdTokenIssuance = $true }
            } -ErrorAction Stop

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
    # Incluir lo ya creado para facilitar limpieza/reintento en el orquestador
    Write-Result -Success $false -Message "Error durante la creación: $($_.Exception.Message)" -Data $out
}
finally {
    Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
}
