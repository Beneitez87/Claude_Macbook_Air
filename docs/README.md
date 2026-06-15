# Documentación — Automatización ciclo de vida de Enterprise Apps

Automatización del ciclo de vida de Enterprise Apps en Microsoft Entra ID,
orquestada desde ServiceNow e implementada en PowerShell + Microsoft Graph.

## Scripts

| Fase | Script | Documentación |
|---|---|---|
| 1 | [`Fase1_Gestión_Usuarios_EnterpriseApp.ps1`](../Fase1_Gestión_Usuarios_EnterpriseApp.ps1) | [Gestión de usuarios y grupos](Fase1_Gestion_Usuarios.md) |
| 2 | [`Fase2_Creacion_EnterpriseApp.ps1`](../Fase2_Creacion_EnterpriseApp.ps1) | [Creación de Enterprise Apps](Fase2_Creacion_EnterpriseApp.md) |

## Permisos API por script — vista rápida

Todos son permisos de **tipo Aplicación** (flujo client-credentials) y requieren
**consentimiento de administrador**.

| Permiso Graph | Fase 1 | Fase 2 |
|---|:---:|:---:|
| `AppRoleAssignment.ReadWrite.All` | ✅ | ✅ |
| `Application.Read.All` | ✅ | — *(cubierto por ReadWrite)* |
| `Application.ReadWrite.All` | — | ✅ |
| `DelegatedPermissionGrant.ReadWrite.All` | — | ✅ |
| `Directory.Read.All` | ✅ | ✅ |

> Recomendación: **una app ejecutora por fase** (o al menos separar la de Fase 2,
> de alto privilegio, de la de Fase 1). Así se aplica mínimo privilegio a cada
> proceso y se acota el impacto si una credencial se ve comprometida.

## Modelo común del ejecutor

- **Autenticación:** client credentials (client_id + secret). El secreto se pasa
  como parámetro; los scripts no lo persisten en claro.
- **Contrato de salida:** una línea JSON (`success` / `message` / `timestamp` / `data`),
  código de salida `0` (éxito) o `1` (error). ServiceNow lo parsea para su lógica.
- **Validación previa:** el formato de los GUID y los prerrequisitos se comprueban
  **antes** de conectar a Graph; las entradas inválidas no llegan a tocar el tenant.
- **Sin secretos en el repositorio:** las credenciales viven en el almacén de
  ServiceNow / Key Vault, nunca en el código ni en los commits.

La Fase 2 incluye además una **nota de seguridad ampliada** sobre el carácter de
alto privilegio de su app ejecutora — véase su documento.

## Pruebas

Suite de regresión Pester en [`tests/`](../tests). Ejecutar antes de cualquier
prueba real sobre el tenant:

```bash
pwsh -c "Invoke-Pester ./tests"
```
