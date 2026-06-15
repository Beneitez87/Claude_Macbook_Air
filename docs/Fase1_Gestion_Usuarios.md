# Fase 1 — Gestión de usuarios y grupos en Enterprise Apps

Script: [`Fase1_Gestión_Usuarios_EnterpriseApp.ps1`](../Fase1_Gestión_Usuarios_EnterpriseApp.ps1)

## Propósito

Añade (`Add`) o elimina (`Remove`) la asignación de un **usuario** o **grupo** a una
Enterprise App (service principal) de Entra ID. Pensado para invocarse desde
ServiceNow (MID Server o REST step). Devuelve un único JSON con el resultado.

La operación es **idempotente**: si la asignación ya existe (Add) o ya no existe
(Remove), el script termina con éxito sin realizar cambios.

## Requisitos de ejecución

| Requisito | Valor |
|---|---|
| PowerShell | 5.1+ (`#Requires -Version 5.1`) — compatible con el MID Server Windows |
| Módulos Graph | `Microsoft.Graph.Authentication`, `Microsoft.Graph.Applications`, `Microsoft.Graph.DirectoryObjects` |
| Autenticación | Client credentials (client_id + secret) de la **app ejecutora** |

> El script auto-instala los módulos que falten (Scope `CurrentUser`, NuGet y
> PSGallery endurecidos para entornos no interactivos).

## Permisos API de la Enterprise App ejecutora

Todos son permisos de **tipo Aplicación** (flujo client-credentials, sin usuario
interactivo) y **requieren consentimiento de administrador**.

| Permiso Graph | Tipo | Cmdlets que lo consumen | Para qué |
|---|---|---|---|
| `AppRoleAssignment.ReadWrite.All` | Application | `New-MgServicePrincipalAppRoleAssignedTo`, `Remove-MgServicePrincipalAppRoleAssignedTo` | Crear y eliminar la asignación usuario/grupo ↔ enterprise app |
| `Application.Read.All` | Application | `Get-MgServicePrincipal`, `Get-MgServicePrincipalAppRoleAssignedTo` | Leer la enterprise app destino y sus asignaciones existentes (control de idempotencia) |
| `Directory.Read.All` | Application | `Get-MgDirectoryObject` | Resolver si el `PrincipalId` es usuario, grupo o service principal |

**Conjunto mínimo recomendado:** los tres permisos anteriores.

> **Simplificación opcional:** `Directory.Read.All` es un superconjunto de lectura
> que también cubre la lectura de service principals, por lo que podría sustituir a
> `Application.Read.All`. Se documentan por separado para reflejar la intención de
> mínimo privilegio y dejar claro el porqué de cada uno.

### Concesión del consentimiento

Una sola vez, con una cuenta **Administrador Global** o **Administrador de rol
con privilegios**:

1. Entra portal → **App registrations** → app ejecutora → **API permissions**.
2. **Add a permission** → Microsoft Graph → **Application permissions** → añadir los tres.
3. **Grant admin consent for `<tenant>`**.

## Parámetros

| Parámetro | Obligatorio | Descripción |
|---|---|---|
| `TenantId` | Sí | GUID del tenant |
| `ClientId` | Sí | App ID de la app ejecutora |
| `ClientSecret` | Sí | Secret de la app ejecutora |
| `ServicePrincipalId` | Sí | ObjectId de la enterprise app destino |
| `Action` | Sí | `Add` o `Remove` |
| `PrincipalId` | Sí | ObjectId del usuario o grupo a asignar/desasignar |
| `AppRoleId` | No | App role a asignar; por defecto el rol de acceso por defecto (`00000000-0000-0000-0000-000000000000`) |

Todos los GUID se validan de formato **antes** de conectar a Graph; un GUID mal
formado devuelve un JSON de error sin tocar el tenant.

## Contrato de salida (JSON)

Una única línea JSON por `Write-Output`. Código de salida `0` en éxito, `1` en error.

```json
{
  "success": true,
  "message": "Asignación creada correctamente.",
  "timestamp": "2026-06-15T19:16:22Z",
  "data": {
    "assignmentId": "…",
    "principalId": "…",
    "principalType": "User",
    "appRoleId": "00000000-0000-0000-0000-000000000000",
    "enterpriseApp": "Nombre de la app"
  }
}
```

| Campo | Significado |
|---|---|
| `success` | `true`/`false` — eje de la lógica de error en ServiceNow |
| `message` | Mensaje legible (incluye el detalle del error si lo hubo) |
| `timestamp` | UTC ISO-8601 (`…Z`) |
| `data` | Detalle de la operación (o `null` en validaciones fallidas) |

> En PowerShell, `ConvertFrom-Json` convierte `timestamp` a `[DateTime]`
> automáticamente; ServiceNow, que parsea JSON como texto, recibe el string limpio.

## Ejemplo de invocación

```powershell
.\Fase1_Gestión_Usuarios_EnterpriseApp.ps1 `
    -TenantId           "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
    -ClientId           "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
    -ClientSecret       "********" `
    -ServicePrincipalId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
    -Action             "Add" `
    -PrincipalId        "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
```

## Notas operativas

- Si la app ejecutora carece de `Directory.Read.All`, la resolución del tipo de
  principal falla y el error puede reportarse como *«objeto no encontrado»* (un 403
  enmascarado). Verifique el consentimiento si ve ese mensaje de forma inesperada.
- El script se desconecta de Graph al finalizar (`Disconnect-MgGraph`).

## Pruebas

Suite de regresión en [`tests/`](../tests). Antes de cualquier ejecución real:

```bash
pwsh -c "Invoke-Pester ./tests"
```
