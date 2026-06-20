# Gestión del ciclo de vida de Enterprise Apps — script unificado

Script: [`EnterpriseApp_Lifecycle.ps1`](../EnterpriseApp_Lifecycle.ps1)

Fusiona las antiguas Fase 1 (asignaciones de usuarios/grupos) y Fase 2 (creación
de Enterprise Apps) en un único script con un selector de operación.

## Operaciones (`-Operation`)

| Operación | Qué hace |
|---|---|
| `Create` | Crea una app registration + service principal con configuración completa: propietarios, permisos API (con admin consent), secreto, certificado y SSO (SAML u OIDC). |
| `Add` | Asigna un usuario o grupo a una enterprise app existente (idempotente). |
| `Remove` | Elimina la asignación de un usuario o grupo (idempotente). |

## Requisitos de ejecución

| Requisito | Valor |
|---|---|
| PowerShell | **7.0+** (`#Requires -Version 7.0`) — necesario para la generación de certificado multiplataforma. Si su MID Server usa Windows PowerShell 5.1, instale PowerShell 7. |
| Autenticación | Client credentials (client_id + secret) de la **app ejecutora** |
| Módulos (`Create`) | `Microsoft.Graph.Authentication`, `.Applications`, `.Users`, `.Identity.SignIns` |
| Módulos (`Add`/`Remove`) | `Microsoft.Graph.Authentication`, `.Applications`, `.DirectoryObjects` |

> El script auto-instala los módulos que falten (Scope `CurrentUser`; NuGet y
> PSGallery endurecidos para entornos no interactivos) y solo carga los de la
> operación solicitada.

## Permisos API de la Enterprise App ejecutora

Todos de **tipo Aplicación** (flujo client-credentials) y **requieren
consentimiento de administrador**.

| Permiso Graph | `Create` | `Add` / `Remove` | Para qué |
|---|:---:|:---:|---|
| `Application.ReadWrite.All` | ✅ | — | Crear/configurar app + SP, owners, secreto, certificado, SSO |
| `AppRoleAssignment.ReadWrite.All` | ✅ | ✅ | Conceder permisos de aplicación / crear y eliminar asignaciones de principal |
| `DelegatedPermissionGrant.ReadWrite.All` | ✅ | — | Conceder permisos delegados (admin consent `AllPrincipals`) |
| `Application.Read.All` | — *(cubierto por ReadWrite)* | ✅ | Leer la enterprise app destino y sus asignaciones |
| `Directory.Read.All` | ✅ | ✅ | Resolver owners por UPN / el tipo del principal (usuario, grupo, SP) |

> **Un único ejecutor con el set de `Create` cubre todas las operaciones**
> (`Application.ReadWrite.All` es superconjunto de `Application.Read.All`).
> La app ejecutora de `Create` es de **alto privilegio** — véase la nota de
> seguridad al final.

### Concesión del consentimiento

Una sola vez, con **Administrador Global** o **Administrador de rol con
privilegios**: Entra portal → **App registrations** → app ejecutora →
**API permissions** → añadir los permisos de aplicación → **Grant admin consent**.

## Parámetros

### Comunes (todas las operaciones)

| Parámetro | Obligatorio | Descripción |
|---|---|---|
| `Operation` | Sí | `Create`, `Add` o `Remove` |
| `TenantId` | Sí | GUID del tenant |
| `ClientId` | Sí | App ID de la app ejecutora |
| `ClientSecret` | Sí | Secret de la app ejecutora |

### `Create`

| Parámetro | Obligatorio | Defecto | Descripción |
|---|---|---|---|
| `DisplayName` | Sí | — | Nombre de la app a crear |
| `SignInAudience` | No | `AzureADMyOrg` | `AzureADMyOrg` (single-tenant) o `AzureADMultipleOrgs` |
| `Owners` | No | `@()` | UPN(s) u ObjectId(s) de propietarios |
| `SsoType` | No | `none` | `saml`, `oidc` o `none` |
| `ReplyUrls` | No | `@()` | URLs de respuesta/callback (ACS en SAML, redirect URI en OIDC) |
| `IdentifierUri` | Condicional | — | Entity ID (**obligatorio** para SAML). Ver nota de Entity ID |
| `SignOnUrl` | No | — | (Solo SAML) URL de inicio de sesión (`loginUrl` del SP) |
| `ApiPermissionsJson` | No | — | JSON con permisos a declarar y consentir (ver formato) |
| `RequireAssignment` | No | `$true` | Si la enterprise app exige asignación explícita |
| `GenerateSecret` | No | `$false` | Generar client secret y devolverlo |
| `SecretDescription` | No | `ServiceNow` | Descripción del secreto |
| `SecretExpiryMonths` | No | `24` | Vigencia del secreto en meses |
| `GenerateCert` | No | `$false` | Generar certificado autofirmado y devolver `.cer`/`.pfx` |
| `CertValidityYears` | No | `2` | Validez del certificado en años |
| `CertSubject` | No | `CN=<DisplayName>` | Subject del certificado |
| `NotificationEmail` | No | — | Correo del peticionario (trazabilidad) |
| `AllowDuplicateName` | No | (switch) | Permite crear aunque exista otra app con el mismo `DisplayName` |

### `Add` / `Remove`

| Parámetro | Obligatorio | Defecto | Descripción |
|---|---|---|---|
| `ServicePrincipalId` | Sí | — | ObjectId de la enterprise app destino |
| `PrincipalId` | Sí | — | ObjectId del usuario o grupo |
| `AppRoleId` | No | `00000000-…-0` | App role a asignar (rol de acceso por defecto) |

### Nota de Entity ID (SAML)

Entra exige que `identifierUris` use un **dominio verificado** del tenant o el
formato **`api://{appId}`**. Un host arbitrario (`https://mi-app`) se rechaza con
`HostNameNotOnVerifiedDomain`. El parámetro `-IdentifierUri` admite el **token
`{appId}`**, que el script sustituye por el App ID generado:

```
-IdentifierUri "api://{appId}"
```

### Formato de `ApiPermissionsJson`

```json
[
  {
    "resourceAppId": "00000003-0000-0000-c000-000000000000",
    "delegated":   ["User.Read", "Mail.Read"],
    "application": ["User.Read.All"]
  }
]
```

## Robustez frente a la replicación de Entra

Tras crear app/SP, los objetos tardan unos segundos en replicarse en todos los
nodos de Graph. **Todas las mutaciones posteriores a la creación** (SP, owners,
permisos, secreto, certificado, SSO) se reintentan con backoff
(`Invoke-WithRetry`), reconociendo las firmas de error transitorias observadas en
pruebas reales: `does not exist`, `does not reference a valid application object`,
`ResourceNotFound`/`ObjectNotFound`, `Unable to read the company information`, etc.

## Contrato de salida (JSON)

Una única línea JSON por `Write-Output`. Código de salida `0` (éxito) o `1` (error).

```json
{ "success": true, "message": "…", "timestamp": "2026-06-20T15:49:16Z", "data": { … } }
```

| Campo | Significado |
|---|---|
| `success` | `true`/`false` — eje de la lógica de error en ServiceNow |
| `message` | Mensaje legible (incluye el detalle del error si lo hubo) |
| `timestamp` | UTC ISO-8601 (`…Z`) |
| `data` | Detalle de la operación (incluye `operation`); en `Create` acumula lo ya creado aunque un paso falle |

> En PowerShell, `ConvertFrom-Json` convierte `timestamp` a `[DateTime]`
> automáticamente; ServiceNow, que parsea JSON como texto, recibe el string limpio.

> **`Create` con secreto/certificado devuelve material sensible** en `data`
> (`secret.value`, `certificate.pfxBase64`, `certificate.pfxPassword`). El
> orquestador debe tratar la salida como secreta: no registrarla, TLS, y
> descartarla tras la entrega.

## Ejemplos

```powershell
# Crear una app sencilla con secreto, sin SSO ni permisos
.\EnterpriseApp_Lifecycle.ps1 -Operation Create -TenantId <guid> -ClientId <guid> `
    -ClientSecret <secret> -DisplayName "Mi App" -GenerateSecret $true

# Crear app SAML con permisos y Entity ID api://{appId}
.\EnterpriseApp_Lifecycle.ps1 -Operation Create -TenantId <guid> -ClientId <guid> `
    -ClientSecret <secret> -DisplayName "Mi App SAML" -GenerateSecret $true `
    -SsoType saml -IdentifierUri "api://{appId}" -ReplyUrls "https://ejemplo.com" `
    -SignOnUrl "https://ejemplo.com" `
    -ApiPermissionsJson '[{"resourceAppId":"00000003-0000-0000-c000-000000000000","delegated":["Sites.Selected"],"application":["Group.Read.All"]}]'

# Asignar un usuario o grupo a una enterprise app existente
.\EnterpriseApp_Lifecycle.ps1 -Operation Add -TenantId <guid> -ClientId <guid> `
    -ClientSecret <secret> -ServicePrincipalId <spId> -PrincipalId <userOrGroupId>

# Eliminar la asignación
.\EnterpriseApp_Lifecycle.ps1 -Operation Remove -TenantId <guid> -ClientId <guid> `
    -ClientSecret <secret> -ServicePrincipalId <spId> -PrincipalId <userOrGroupId>
```

## Nota de seguridad — app ejecutora de alto privilegio (`Create`)

La combinación `Application.ReadWrite.All` + `AppRoleAssignment.ReadWrite.All` +
`DelegatedPermissionGrant.ReadWrite.All` permite crear aplicaciones y
**concederles cualquier permiso de Graph** — una vía conocida de escalada de
privilegios. Trate la app ejecutora en consecuencia:

- App ejecutora **dedicada** a esta automatización.
- Credencial en un **almacén seguro** (ServiceNow Credential Store / Key Vault).
- **Secretos cortos con rotación**; preferir certificado cuando sea viable.
- **Acceso condicional / lista de IP** restringiendo desde dónde autentica.
- **Monitorización** de inicios de sesión y auditoría.

## Limitaciones conocidas (no bloqueantes)

- **SAML**: se fija `PreferredSingleSignOnMode`, Entity ID, Reply URL y Sign-on URL.
  Un SSO SAML plenamente funcional suele requerir además el certificado de **firma**
  SAML y el mapeo de claims (paso posterior según el caso).
- **Bloque de permisos vacío**: un bloque con `resourceAppId` pero sin permisos
  genera un `requiredResourceAccess` vacío que Graph podría rechazar.

## Pruebas

Suite de regresión Pester en [`tests/`](../tests) (Create y Assign). Antes de
cualquier ejecución real:

```bash
pwsh -c "Invoke-Pester ./tests"
```
