# ──────────────────────────────────────────────────────────────────────────
# Tests del script unificado — operaciones Add / Remove (asignaciones).
# Pester 5.x
# ──────────────────────────────────────────────────────────────────────────

BeforeAll {
    . $PSScriptRoot/_TestHelpers.ps1

    # Stubs de los cmdlets de Graph usados por las funciones bajo prueba.
    function Get-MgDirectoryObject { [CmdletBinding()] param([string]$DirectoryObjectId) }
    function Get-MgServicePrincipalAppRoleAssignedTo { [CmdletBinding()] param([string]$ServicePrincipalId, [switch]$All) }

    . ([scriptblock]::Create((Get-ScriptFunctionText -Path $ScriptPath -Name 'Test-IsGuid','Get-PrincipalType','Get-ExistingAssignment')))
}

Describe 'Lifecycle :: Test-IsGuid' {
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
}

Describe 'Lifecycle :: Get-PrincipalType' {
    It 'detecta User vía @odata.type en AdditionalProperties' {
        Mock Get-MgDirectoryObject {
            [pscustomobject]@{ AdditionalProperties = @{ '@odata.type' = '#microsoft.graph.user' }; ODataType = $null }
        }
        Get-PrincipalType -ObjectId $DummyGuid | Should -Be 'User'
    }
    It 'detecta Group' {
        Mock Get-MgDirectoryObject {
            [pscustomobject]@{ AdditionalProperties = @{ '@odata.type' = '#microsoft.graph.group' }; ODataType = $null }
        }
        Get-PrincipalType -ObjectId $DummyGuid | Should -Be 'Group'
    }
    It 'detecta ServicePrincipal' {
        Mock Get-MgDirectoryObject {
            [pscustomobject]@{ AdditionalProperties = @{ '@odata.type' = '#microsoft.graph.servicePrincipal' }; ODataType = $null }
        }
        Get-PrincipalType -ObjectId $DummyGuid | Should -Be 'ServicePrincipal'
    }
    It 'usa el fallback a ODataType cuando AdditionalProperties está vacío' {
        Mock Get-MgDirectoryObject {
            [pscustomobject]@{ AdditionalProperties = @{}; ODataType = '#microsoft.graph.user' }
        }
        Get-PrincipalType -ObjectId $DummyGuid | Should -Be 'User'
    }
    It 'lanza excepción si el objeto no existe' {
        Mock Get-MgDirectoryObject { $null }
        { Get-PrincipalType -ObjectId $DummyGuid } | Should -Throw '*No se encontró*'
    }
    It 'lanza excepción ante un tipo no soportado (ej. device)' {
        Mock Get-MgDirectoryObject {
            [pscustomobject]@{ AdditionalProperties = @{ '@odata.type' = '#microsoft.graph.device' }; ODataType = $null }
        }
        { Get-PrincipalType -ObjectId $DummyGuid } | Should -Throw '*tipo no soportado*'
    }
}

Describe 'Lifecycle :: Get-ExistingAssignment' {
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
        (Get-ExistingAssignment -SpId $DummyGuid -PrinId $prin -RoleId $role).Id | Should -Be 'A'
    }
    It 'devuelve null si el rol no coincide' {
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
# Integración: fichero real, entradas que fallan en validación (paso 0).
# ──────────────────────────────────────────────────────────────────────────
Describe 'Lifecycle :: Add/Remove — validación y contrato JSON (fichero real)' {
    It 'rechaza un TenantId con formato no-GUID' {
        $r = Invoke-RealScript -Path $ScriptPath -ScriptArgs @(
            '-Operation','Add', '-TenantId','no-guid', '-ClientId',$DummyGuid, '-ClientSecret','x',
            '-ServicePrincipalId',$DummyGuid, '-PrincipalId',$DummyGuid)
        $r.ExitCode     | Should -Be 1
        $r.Json.success | Should -BeFalse
        $r.Json.message | Should -BeLike '*TenantId*'
    }
    It 'el JSON de salida tiene el contrato esperado (success/message/timestamp/data)' {
        $r = Invoke-RealScript -Path $ScriptPath -ScriptArgs @(
            '-Operation','Add', '-TenantId','no-guid', '-ClientId',$DummyGuid, '-ClientSecret','x',
            '-ServicePrincipalId',$DummyGuid, '-PrincipalId',$DummyGuid)
        $r.Json.PSObject.Properties.Name | Should -Contain 'success'
        $r.Json.PSObject.Properties.Name | Should -Contain 'message'
        $r.Json.PSObject.Properties.Name | Should -Contain 'timestamp'
        $r.Json.PSObject.Properties.Name | Should -Contain 'data'
        # Formato sobre el JSON crudo (lo que recibe ServiceNow):
        $r.Stdout | Should -Match '"timestamp":"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z"'
    }
    It 'rechaza un PrincipalId con formato no-GUID (Remove)' {
        $r = Invoke-RealScript -Path $ScriptPath -ScriptArgs @(
            '-Operation','Remove', '-TenantId',$DummyGuid, '-ClientId',$DummyGuid, '-ClientSecret','x',
            '-ServicePrincipalId',$DummyGuid, '-PrincipalId','malo')
        $r.ExitCode     | Should -Be 1
        $r.Json.success | Should -BeFalse
        $r.Json.message | Should -BeLike '*PrincipalId*'
    }
}
