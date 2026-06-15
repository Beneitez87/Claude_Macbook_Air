# ──────────────────────────────────────────────────────────────────────────
# Tests de Fase 1 — Gestión de usuarios/grupos en Enterprise Apps.
# Pester 5.x
# ──────────────────────────────────────────────────────────────────────────

BeforeAll {
    . $PSScriptRoot/_TestHelpers.ps1

    # Stubs de los cmdlets de Graph que usan las funciones bajo prueba.
    # Pester los sobreescribe (Mock) en cada test.
    function Get-MgDirectoryObject { [CmdletBinding()] param([string]$DirectoryObjectId) }
    function Get-MgServicePrincipalAppRoleAssignedTo { [CmdletBinding()] param([string]$ServicePrincipalId, [switch]$All) }

    # Cargar las funciones reales del script Fase 1 en este scope.
    . ([scriptblock]::Create((Get-ScriptFunctionText -Path $Fase1Path -Name 'Test-IsGuid','Get-PrincipalType','Get-ExistingAssignment')))
}

Describe 'Fase1 :: Test-IsGuid' {
    It 'acepta un GUID con guiones válido' {
        Test-IsGuid -Value '3fa85f64-5717-4562-b3fc-2c963f66afa6' | Should -BeTrue
    }
    It 'acepta el GUID por defecto de AppRole (todo ceros)' {
        Test-IsGuid -Value '00000000-0000-0000-0000-000000000000' | Should -BeTrue
    }
    It 'rechaza una cadena que no es GUID' {
        Test-IsGuid -Value 'no-soy-un-guid' | Should -BeFalse
    }
    It 'rechaza cadena vacía' {
        Test-IsGuid -Value '' | Should -BeFalse
    }
    It 'rechaza un GUID truncado' {
        Test-IsGuid -Value '3fa85f64-5717-4562-b3fc' | Should -BeFalse
    }
}

Describe 'Fase1 :: Get-PrincipalType' {
    It 'detecta User vía @odata.type en AdditionalProperties' {
        Mock Get-MgDirectoryObject {
            [pscustomobject]@{
                AdditionalProperties = @{ '@odata.type' = '#microsoft.graph.user' }
                ODataType            = $null
            }
        }
        Get-PrincipalType -ObjectId $DummyGuid | Should -Be 'User'
    }
    It 'detecta Group' {
        Mock Get-MgDirectoryObject {
            [pscustomobject]@{
                AdditionalProperties = @{ '@odata.type' = '#microsoft.graph.group' }
                ODataType            = $null
            }
        }
        Get-PrincipalType -ObjectId $DummyGuid | Should -Be 'Group'
    }
    It 'detecta ServicePrincipal' {
        Mock Get-MgDirectoryObject {
            [pscustomobject]@{
                AdditionalProperties = @{ '@odata.type' = '#microsoft.graph.servicePrincipal' }
                ODataType            = $null
            }
        }
        Get-PrincipalType -ObjectId $DummyGuid | Should -Be 'ServicePrincipal'
    }
    It 'usa el fallback a ODataType cuando AdditionalProperties está vacío' {
        Mock Get-MgDirectoryObject {
            [pscustomobject]@{
                AdditionalProperties = @{}
                ODataType            = '#microsoft.graph.user'
            }
        }
        Get-PrincipalType -ObjectId $DummyGuid | Should -Be 'User'
    }
    It 'lanza excepción si el objeto no existe' {
        Mock Get-MgDirectoryObject { $null }
        { Get-PrincipalType -ObjectId $DummyGuid } | Should -Throw '*No se encontró*'
    }
    It 'lanza excepción ante un tipo no soportado (ej. device)' {
        Mock Get-MgDirectoryObject {
            [pscustomobject]@{
                AdditionalProperties = @{ '@odata.type' = '#microsoft.graph.device' }
                ODataType            = $null
            }
        }
        { Get-PrincipalType -ObjectId $DummyGuid } | Should -Throw '*tipo no soportado*'
    }
}

Describe 'Fase1 :: Get-ExistingAssignment' {
    BeforeAll {
        $role = '00000000-0000-0000-0000-000000000000'
        $prin = '22222222-2222-2222-2222-222222222222'
    }
    It 'devuelve la asignación que coincide en principal y rol' {
        Mock Get-MgServicePrincipalAppRoleAssignedTo {
            @(
                [pscustomobject]@{ Id = 'A'; PrincipalId = $prin; AppRoleId = $role }
                [pscustomobject]@{ Id = 'B'; PrincipalId = 'otro'; AppRoleId = $role }
            )
        }
        $r = Get-ExistingAssignment -SpId $DummyGuid -PrinId $prin -RoleId $role
        $r.Id | Should -Be 'A'
    }
    It 'devuelve null si el rol no coincide (mismo principal, otro rol)' {
        Mock Get-MgServicePrincipalAppRoleAssignedTo {
            @( [pscustomobject]@{ Id = 'A'; PrincipalId = $prin; AppRoleId = 'rol-distinto' } )
        }
        Get-ExistingAssignment -SpId $DummyGuid -PrinId $prin -RoleId $role | Should -BeNullOrEmpty
    }
    It 'devuelve null si no hay ninguna asignación' {
        Mock Get-MgServicePrincipalAppRoleAssignedTo { @() }
        Get-ExistingAssignment -SpId $DummyGuid -PrinId $prin -RoleId $role | Should -BeNullOrEmpty
    }
}

# ──────────────────────────────────────────────────────────────────────────
# Integración: se ejecuta el FICHERO REAL en un pwsh hijo. Todas estas
# entradas fallan en la validación inicial (paso 0), ANTES de cargar módulos
# o conectar a Graph, por lo que no se toca el tenant.
# ──────────────────────────────────────────────────────────────────────────
Describe 'Fase1 :: contrato JSON y puertas de validación (fichero real)' {
    It 'rechaza un TenantId con formato no-GUID y emite JSON de error' {
        $r = Invoke-RealScript -Path $Fase1Path -ScriptArgs @(
            '-TenantId','no-guid', '-ClientId',$DummyGuid, '-ClientSecret','x',
            '-ServicePrincipalId',$DummyGuid, '-Action','Add', '-PrincipalId',$DummyGuid)
        $r.ExitCode      | Should -Be 1
        $r.Json.success  | Should -BeFalse
        $r.Json.message  | Should -BeLike '*TenantId*'
    }
    It 'el JSON de salida tiene el contrato esperado (success/message/timestamp/data)' {
        $r = Invoke-RealScript -Path $Fase1Path -ScriptArgs @(
            '-TenantId','no-guid', '-ClientId',$DummyGuid, '-ClientSecret','x',
            '-ServicePrincipalId',$DummyGuid, '-Action','Add', '-PrincipalId',$DummyGuid)
        $r.Json.PSObject.Properties.Name | Should -Contain 'success'
        $r.Json.PSObject.Properties.Name | Should -Contain 'message'
        $r.Json.PSObject.Properties.Name | Should -Contain 'timestamp'
        $r.Json.PSObject.Properties.Name | Should -Contain 'data'
        # Validamos el formato sobre el JSON CRUDO (lo que recibe ServiceNow):
        # ConvertFrom-Json en PowerShell auto-convertiría el string ISO-8601 a
        # [DateTime], ocultando el formato real del cable.
        $r.Stdout | Should -Match '"timestamp":"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z"'
    }
    It 'rechaza un PrincipalId con formato no-GUID' {
        $r = Invoke-RealScript -Path $Fase1Path -ScriptArgs @(
            '-TenantId',$DummyGuid, '-ClientId',$DummyGuid, '-ClientSecret','x',
            '-ServicePrincipalId',$DummyGuid, '-Action','Remove', '-PrincipalId','malo')
        $r.ExitCode     | Should -Be 1
        $r.Json.success | Should -BeFalse
        $r.Json.message | Should -BeLike '*PrincipalId*'
    }
}
