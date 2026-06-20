# Documentación — Automatización ciclo de vida de Enterprise Apps

Automatización del ciclo de vida de Enterprise Apps en Microsoft Entra ID,
orquestada desde ServiceNow e implementada en PowerShell + Microsoft Graph.

## Script

Las antiguas Fase 1 y Fase 2 están **fusionadas** en un único script con un
selector de operación:

| Script | Documentación |
|---|---|
| [`EnterpriseApp_Lifecycle.ps1`](../EnterpriseApp_Lifecycle.ps1) | [Gestión del ciclo de vida](EnterpriseApp_Lifecycle.md) |

| Operación | Equivalencia anterior | Qué hace |
|---|---|---|
| `Create` | Fase 2 | Crea app registration + service principal (owners, permisos+consent, secreto, certificado, SSO) |
| `Add` | Fase 1 | Asigna un usuario o grupo a una enterprise app |
| `Remove` | Fase 1 | Elimina la asignación de un usuario o grupo |

## Permisos API del ejecutor — vista rápida

Todos de **tipo Aplicación** y con **consentimiento de administrador**.

| Permiso Graph | `Create` | `Add` / `Remove` |
|---|:---:|:---:|
| `Application.ReadWrite.All` | ✅ | — |
| `AppRoleAssignment.ReadWrite.All` | ✅ | ✅ |
| `DelegatedPermissionGrant.ReadWrite.All` | ✅ | — |
| `Application.Read.All` | — *(cubierto por ReadWrite)* | ✅ |
| `Directory.Read.All` | ✅ | ✅ |

> Un único ejecutor con el set de `Create` cubre todas las operaciones. La de
> `Create` es de **alto privilegio** — véase la nota de seguridad en su documento.

## Modelo común del ejecutor

- **Autenticación:** client credentials (client_id + secret). El secreto se pasa
  como parámetro; el script no lo persiste en claro.
- **Contrato de salida:** una línea JSON (`success` / `message` / `timestamp` / `data`),
  código de salida `0` (éxito) o `1` (error).
- **Validación previa:** formato de GUID y prerrequisitos se comprueban **antes**
  de conectar a Graph; las entradas inválidas no llegan a tocar el tenant.
- **Robustez:** todas las mutaciones post-creación se reintentan ante la latencia
  de replicación de Entra.
- **Sin secretos en el repositorio:** las credenciales viven en el almacén de
  ServiceNow / Key Vault.

## Pruebas

Suite de regresión Pester en [`tests/`](../tests). Ejecutar antes de cualquier
prueba real sobre el tenant:

```bash
pwsh -c "Invoke-Pester ./tests"
```
