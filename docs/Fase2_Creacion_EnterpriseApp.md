# Fase 2 — Creación de Enterprise Apps

Script: [`Fase2_Creacion_EnterpriseApp.ps1`](../Fase2_Creacion_EnterpriseApp.ps1)

## Propósito

Crea una **app registration + service principal** con configuración completa en un
solo paso: propietarios, permisos API (con admin consent), secreto, certificado
autofirmado y SSO (SAML u OIDC). Pensado para invocarse desde ServiceNow.

El secreto, el certificado (`.cer` y `.pfx` en base64) y el XML de metadatos SAML
se devuelven **dentro del JSON de salida** para que el orquestador los gestione
(el envío por correo se implementará como módulo aparte).

La salida acumula lo ya creado paso a paso: si un paso falla, el JSON de error
incluye los objetos ya generados para facilitar limpieza/reintento.

## Requisitos de ejecución

| Requisito | Valor |
|---|---|
| PowerShell | 7.0+ (`#Requires -Version 7.0`) — necesario para la generación de certificado multiplataforma (.NET `CertificateRequest`) |
| Módulos Graph | `Microsoft.Graph.Authentication`, `Microsoft.Graph.Applications`, `Microsoft.Graph.Users`, `Microsoft.Graph.Identity.SignIns` |
| Autenticación | Client credentials de la **app ejecutora** |

> Resistente a la latencia de replicación de Entra: las asignaciones de
> propietarios y permisos se reintentan con backoff (`Invoke-WithRetry`) ante
> errores transitorios de tipo *ResourceNotFound*.

## Permisos API de la Enterprise App ejecutora

Todos de **tipo Aplicación** y **requieren consentimiento de administrador**.
Esta app ejecutora es de **alto privilegio** — véase la nota de seguridad al final.

| Permiso Graph | Tipo | Cmdlets que lo consumen | Para qué |
|---|---|---|---|
| `Application.ReadWrite.All` | Application | `New-MgApplication`, `New-MgServicePrincipal`, `Update-MgApplication`, `New-MgApplicationOwnerByRef`, `Add-MgApplicationPassword`, `Update-MgServicePrincipal` | Crear y configurar la app registration y su SP: propietarios, secreto, certificado, SSO |
| `AppRoleAssignment.ReadWrite.All` | Application | `New-MgServicePrincipalAppRoleAssignment` | Conceder los permisos de **aplicación** declarados (admin consent vía app role assignment) |
| `DelegatedPermissionGrant.ReadWrite.All` | Application | `New-MgOauth2PermissionGrant` | Conceder los permisos **delegados** a nivel de tenant (admin consent `AllPrincipals`) |
| `Directory.Read.All` | Application | `Get-MgUser`, `Get-MgServicePrincipal` | Resolver propietarios por UPN → ObjectId y localizar el SP del recurso (Graph, etc.) al resolver permisos |

**Conjunto mínimo recomendado:** los cuatro permisos anteriores.

> **Matices de mínimo privilegio:**
> - `Application.ReadWrite.All` ya cubre lectura/escritura de apps y service
>   principals; por eso `Get-MgServicePrincipal` no necesita permiso adicional.
> - Para resolver propietarios por UPN (`Get-MgUser`) bastaría con
>   `User.Read.All` en lugar de `Directory.Read.All`. Se elige `Directory.Read.All`
>   por ser una única concesión que cubre con holgura ambas lecturas.
> - Si **no** se pasan permisos API en la petición (`ApiPermissionsJson` vacío),
>   `AppRoleAssignment.ReadWrite.All` y `DelegatedPermissionGrant.ReadWrite.All`
>   no llegan a usarse; manténgalos solo si la app ejecutora va a conceder consent.

### Concesión del consentimiento

Una sola vez, con **Administrador Global** o **Administrador de rol con
privilegios**: Entra portal → **App registrations** → app ejecutora →
**API permissions** → añadir los permisos de aplicación → **Grant admin consent**.

## Parámetros

| Parámetro | Obligatorio | Defecto | Descripción |
|---|---|---|---|
| `TenantId` | Sí | — | GUID del tenant |
| `ClientId` | Sí | — | App ID de la app ejecutora |
| `ClientSecret` | Sí | — | Secret de la app ejecutora |
| `DisplayName` | Sí | — | Nombre de la app a crear |
| `SignInAudience` | No | `AzureADMyOrg` | `AzureADMyOrg` (single-tenant) o `AzureADMultipleOrgs` |
| `Owners` | No | `@()` | UPN(s) u ObjectId(s) de propietarios técnicos |
| `SsoType` | No | `none` | `saml`, `oidc` o `none` |
| `ReplyUrls` | No | `@()` | URLs de respuesta/callback (ACS en SAML, redirect URI en OIDC) |
| `IdentifierUri` | Condicional | — | Entity ID / Identifier URI (**obligatorio** para SAML) |
| `ApiPermissionsJson` | No | — | JSON con los permisos API a declarar y consentir (ver formato abajo) |
| `RequireAssignment` | No | `$true` | Si la enterprise app exige asignación explícita de usuario |
| `GenerateSecret` | No | `$false` | Generar client secret y devolverlo |
| `SecretDescription` | No | `ServiceNow` | Descripción del secreto |
| `SecretExpiryMonths` | No | `24` | Vigencia del secreto en meses |
| `GenerateCert` | No | `$false` | Generar certificado autofirmado, subirlo y devolver `.cer`/`.pfx` |
| `CertValidityYears` | No | `2` | Validez del certificado en años (24 meses) |
| `CertSubject` | No | `CN=<DisplayName>` | Subject del certificado |
| `NotificationEmail` | No | — | Correo del peticionario (solo trazabilidad en esta versión) |
| `AllowDuplicateName` | No | (switch) | Permite crear aunque exista otra app con el mismo `DisplayName` |

### Formato de `ApiPermissionsJson`

Los **nombres** de permiso se resuelven automáticamente a sus IDs contra el SP del recurso.

```json
[
  {
    "resourceAppId": "00000003-0000-0000-c000-000000000000",
    "delegated":   ["User.Read", "Mail.Read"],
    "application": ["User.Read.All"]
  }
]
```

## Validaciones previas (sin tocar el tenant)

Antes de cargar módulos o conectar a Graph, el script rechaza con JSON de error:

- `TenantId` / `ClientId` con formato no-GUID.
- `SsoType = saml` sin `IdentifierUri`.
- `SsoType ≠ none` sin ninguna `ReplyUrls`.
- `ApiPermissionsJson` mal formado.

## Contrato de salida (JSON)

```json
{
  "success": true,
  "message": "Enterprise app 'Mi App' creada correctamente.",
  "timestamp": "2026-06-15T19:16:22Z",
  "data": {
    "applicationObjectId": "…",
    "appId": "…",
    "servicePrincipalId": "…",
    "displayName": "Mi App",
    "owners": ["…"],
    "apiPermissions": [ { "resourceAppId": "…", "delegated": ["…"], "application": ["…"] } ],
    "secret":      { "keyId": "…", "value": "…", "description": "…", "endDateTime": "…" },
    "certificate": { "thumbprint": "…", "subject": "…", "notAfter": "…", "cerBase64": "…", "pfxBase64": "…", "pfxPassword": "…" },
    "sso":         { "type": "saml", "identifierUri": "…", "replyUrls": ["…"], "metadataUrl": "…", "metadataXml": "…" },
    "notificationEmail": "…"
  }
}
```

> **El campo `data` contiene material sensible** (`secret.value`, `certificate.pfxBase64`,
> `certificate.pfxPassword`). El orquestador debe tratar la salida como secreta:
> no registrarla en logs, transportarla por TLS y descartarla tras la entrega.

## Cobertura funcional, paso a paso

1. Guarda de duplicados por `DisplayName` (comillas escapadas en el filtro OData).
2. `New-MgApplication` (app registration).
3. `New-MgServicePrincipal` (enterprise app), con `appRoleAssignmentRequired`.
4. Propietarios (resolviendo UPN → ObjectId).
5. Permisos API: declaración (`requiredResourceAccess`) + admin consent (delegado y/o aplicación).
6. Secreto (opcional).
7. Certificado autofirmado multiplataforma (opcional): clave pública subida a la app; `.cer`/`.pfx` devueltos.
8. SSO SAML u OIDC.

## Nota de seguridad — app ejecutora de alto privilegio

La combinación `Application.ReadWrite.All` + `AppRoleAssignment.ReadWrite.All` +
`DelegatedPermissionGrant.ReadWrite.All` permite, de facto, crear aplicaciones y
**concederles cualquier permiso de Graph** — es una vía conocida de escalada de
privilegios. Trate la app ejecutora en consecuencia:

- App ejecutora **dedicada** a esta automatización (no reutilizar una de propósito general).
- Credencial en un **almacén seguro** (ServiceNow Credential Store / Key Vault), nunca en claro.
- **Secretos cortos con rotación**; preferir certificado a secreto cuando sea viable.
- **Acceso condicional / lista de IP** restringiendo desde dónde puede autenticarse.
- **Monitorización** de inicios de sesión y registros de auditoría de la app.
- Revisión periódica de mínimo privilegio: retirar `*PermissionGrant*` si no se conceden permisos.

## Limitaciones conocidas (no bloqueantes)

- **SAML**: se fija `PreferredSingleSignOnMode`, `IdentifierUri` y `ReplyUrls`. Un
  SSO SAML plenamente funcional suele requerir además el certificado de **firma**
  SAML y el mapeo de claims (paso posterior según el caso).
- **Bloque de permisos vacío**: un bloque con `resourceAppId` pero sin permisos
  genera un `requiredResourceAccess` vacío que Graph podría rechazar.

## Pruebas

```bash
pwsh -c "Invoke-Pester ./tests"
```
