# ──────────────────────────────────────────────────────────────────────────
# Tests del script unificado — operación Create.
# Pester 5.x
# ──────────────────────────────────────────────────────────────────────────

BeforeAll {
    . $PSScriptRoot/_TestHelpers.ps1

    function Get-MgUser { [CmdletBinding()] param([string]$UserId, [string[]]$Property) }
    function Get-MgServicePrincipal { [CmdletBinding()] param([string]$Filter, [string]$ServicePrincipalId) }

    . ([scriptblock]::Create((Get-ScriptFunctionText -Path $ScriptPath -Name 'Test-IsGuid','Resolve-PrincipalObjectId','Resolve-ResourceAccess','Invoke-WithRetry')))
}

Describe 'Lifecycle :: Resolve-PrincipalObjectId' {
    It 'devuelve el GUID tal cual sin consultar Graph cuando ya es un ObjectId' {
        Mock Get-MgUser { throw 'NO debería llamarse' }
        Resolve-PrincipalObjectId -UserRef $DummyGuid | Should -Be $DummyGuid
        Should -Invoke Get-MgUser -Times 0
    }
    It 'resuelve un UPN a su ObjectId vía Graph' {
        Mock Get-MgUser { [pscustomobject]@{ Id = '99999999-9999-9999-9999-999999999999' } }
        Resolve-PrincipalObjectId -UserRef 'juan@contoso.com' | Should -Be '99999999-9999-9999-9999-999999999999'
        Should -Invoke Get-MgUser -Times 1
    }
    It 'lanza excepción si el UPN no se puede resolver' {
        Mock Get-MgUser { $null }
        { Resolve-PrincipalObjectId -UserRef 'fantasma@contoso.com' } | Should -Throw '*No se pudo resolver*'
    }
}

Describe 'Lifecycle :: Resolve-ResourceAccess' {
    BeforeAll {
        $graphAppId = '00000003-0000-0000-c000-000000000000'
        $script:MakeResourceSp = {
            [pscustomobject]@{
                Id = '12345678-1234-1234-1234-123456789012'
                Oauth2PermissionScopes = @(
                    [pscustomobject]@{ Value = 'User.Read'; Id = 'aaa11111-1111-1111-1111-111111111111' }
                    [pscustomobject]@{ Value = 'Mail.Read'; Id = 'bbb22222-2222-2222-2222-222222222222' }
                )
                AppRoles = @(
                    [pscustomobject]@{ Value = 'User.Read.All'; Id = 'ccc33333-3333-3333-3333-333333333333' }
                )
            }
        }
    }

    It 'resuelve un permiso delegado a type=Scope' {
        Mock Get-MgServicePrincipal { & $MakeResourceSp }
        $block = [pscustomobject]@{ resourceAppId = $graphAppId; delegated = @('User.Read'); application = @() }
        $r = Resolve-ResourceAccess -PermissionBlock $block
        $r.DelegatedScopes | Should -Be @('User.Read')
        $r.RequiredResourceAccess.resourceAccess[0].type | Should -Be 'Scope'
        $r.ResourceSpId | Should -Be '12345678-1234-1234-1234-123456789012'
    }
    It 'resuelve un permiso de aplicación a type=Role' {
        Mock Get-MgServicePrincipal { & $MakeResourceSp }
        $block = [pscustomobject]@{ resourceAppId = $graphAppId; delegated = @(); application = @('User.Read.All') }
        $r = Resolve-ResourceAccess -PermissionBlock $block
        $r.ApplicationRoles[0].value | Should -Be 'User.Read.All'
        $r.RequiredResourceAccess.resourceAccess[0].type | Should -Be 'Role'
    }
    It 'resuelve delegados y aplicación combinados' {
        Mock Get-MgServicePrincipal { & $MakeResourceSp }
        $block = [pscustomobject]@{ resourceAppId = $graphAppId; delegated = @('User.Read','Mail.Read'); application = @('User.Read.All') }
        $r = Resolve-ResourceAccess -PermissionBlock $block
        $r.RequiredResourceAccess.resourceAccess.Count | Should -Be 3
        $r.DelegatedScopes.Count  | Should -Be 2
        $r.ApplicationRoles.Count | Should -Be 1
    }
    It 'lanza excepción si falta resourceAppId' {
        Mock Get-MgServicePrincipal { & $MakeResourceSp }
        { Resolve-ResourceAccess -PermissionBlock ([pscustomobject]@{ delegated = @('User.Read') }) } | Should -Throw "*resourceAppId*"
    }
    It 'lanza excepción si el service principal del recurso no existe' {
        Mock Get-MgServicePrincipal { $null }
        $block = [pscustomobject]@{ resourceAppId = $graphAppId; delegated = @('User.Read') }
        { Resolve-ResourceAccess -PermissionBlock $block } | Should -Throw '*No se encontró el service principal*'
    }
    It 'lanza excepción ante un permiso delegado inexistente' {
        Mock Get-MgServicePrincipal { & $MakeResourceSp }
        $block = [pscustomobject]@{ resourceAppId = $graphAppId; delegated = @('Permiso.Falso'); application = @() }
        { Resolve-ResourceAccess -PermissionBlock $block } | Should -Throw '*permiso delegado*'
    }
    It 'lanza excepción ante un permiso de aplicación inexistente' {
        Mock Get-MgServicePrincipal { & $MakeResourceSp }
        $block = [pscustomobject]@{ resourceAppId = $graphAppId; delegated = @(); application = @('Rol.Falso') }
        { Resolve-ResourceAccess -PermissionBlock $block } | Should -Throw '*permiso de aplicación*'
    }
}

Describe 'Lifecycle :: Invoke-WithRetry' {
    It 'devuelve el valor al primer intento si no hay error' {
        $script:calls = 0
        Invoke-WithRetry -Script { $script:calls++; 'ok' } -MaxAttempts 3 -DelaySeconds 0 | Should -Be 'ok'
        $script:calls | Should -Be 1
    }
    It 'reintenta ante un error transitorio y acaba devolviendo el valor' {
        $script:calls = 0
        $r = Invoke-WithRetry -Script {
            $script:calls++
            if ($script:calls -lt 3) { throw 'Request_ResourceNotFound: does not exist' }
            'ok'
        } -MaxAttempts 5 -DelaySeconds 0
        $r | Should -Be 'ok'; $script:calls | Should -Be 3
    }
    It 'NO reintenta ante un error no transitorio (403) y propaga de inmediato' {
        $script:calls = 0
        { Invoke-WithRetry -Script { $script:calls++; throw 'Authorization_RequestDenied (403)' } -MaxAttempts 4 -DelaySeconds 0 } | Should -Throw '*RequestDenied*'
        $script:calls | Should -Be 1
    }
    It 'trata como transitorio "does not reference a valid application object" (creación del SP)' {
        $script:calls = 0
        $r = Invoke-WithRetry -Script {
            $script:calls++
            if ($script:calls -lt 2) { throw "[Request_BadRequest] : The appId '5c8f7a97' of the service principal does not reference a valid application object." }
            'ok'
        } -MaxAttempts 4 -DelaySeconds 0
        $r | Should -Be 'ok'; $script:calls | Should -Be 2
    }
    It 'trata como transitorio "Unable to read the company information" (consent)' {
        $script:calls = 0
        $r = Invoke-WithRetry -Script {
            $script:calls++
            if ($script:calls -lt 2) { throw "[Directory_ObjectNotFound] : Unable to read the company information from the directory." }
            'ok'
        } -MaxAttempts 4 -DelaySeconds 0
        $r | Should -Be 'ok'; $script:calls | Should -Be 2
    }
    It 'se rinde y propaga tras agotar los intentos en error transitorio' {
        $script:calls = 0
        { Invoke-WithRetry -Script { $script:calls++; throw 'ResourceNotFound' } -MaxAttempts 3 -DelaySeconds 0 } | Should -Throw '*ResourceNotFound*'
        $script:calls | Should -Be 3
    }
}

# ──────────────────────────────────────────────────────────────────────────
# Integración: fichero real, entradas que fallan en validación (paso 0).
# ──────────────────────────────────────────────────────────────────────────
Describe 'Lifecycle :: Create — validación (fichero real)' {
    It 'rechaza TenantId no-GUID' {
        $r = Invoke-RealScript -Path $ScriptPath -ScriptArgs @(
            '-Operation','Create', '-TenantId','malo', '-ClientId',$DummyGuid, '-ClientSecret','x', '-DisplayName','TestApp')
        $r.ExitCode | Should -Be 1; $r.Json.success | Should -BeFalse; $r.Json.message | Should -BeLike '*TenantId*'
    }
    It 'rechaza Create sin DisplayName' {
        $r = Invoke-RealScript -Path $ScriptPath -ScriptArgs @(
            '-Operation','Create', '-TenantId',$DummyGuid, '-ClientId',$DummyGuid, '-ClientSecret','x')
        $r.ExitCode | Should -Be 1; $r.Json.success | Should -BeFalse; $r.Json.message | Should -BeLike '*DisplayName*'
    }
    It 'SSO saml sin IdentifierUri es rechazado' {
        $r = Invoke-RealScript -Path $ScriptPath -ScriptArgs @(
            '-Operation','Create', '-TenantId',$DummyGuid, '-ClientId',$DummyGuid, '-ClientSecret','x',
            '-DisplayName','TestApp', '-SsoType','saml')
        $r.ExitCode | Should -Be 1; $r.Json.success | Should -BeFalse; $r.Json.message | Should -BeLike '*IdentifierUri*'
    }
    It 'SSO oidc sin ReplyUrls es rechazado' {
        $r = Invoke-RealScript -Path $ScriptPath -ScriptArgs @(
            '-Operation','Create', '-TenantId',$DummyGuid, '-ClientId',$DummyGuid, '-ClientSecret','x',
            '-DisplayName','TestApp', '-SsoType','oidc')
        $r.ExitCode | Should -Be 1; $r.Json.success | Should -BeFalse; $r.Json.message | Should -BeLike '*ReplyUrls*'
    }
    It 'ApiPermissionsJson mal formado es rechazado' {
        $r = Invoke-RealScript -Path $ScriptPath -ScriptArgs @(
            '-Operation','Create', '-TenantId',$DummyGuid, '-ClientId',$DummyGuid, '-ClientSecret','x',
            '-DisplayName','TestApp', '-ApiPermissionsJson','{esto no es json')
        $r.ExitCode | Should -Be 1; $r.Json.success | Should -BeFalse; $r.Json.message | Should -BeLike '*JSON*'
    }
    It 'rechaza -SignOnUrl cuando el SSO no es SAML' {
        $r = Invoke-RealScript -Path $ScriptPath -ScriptArgs @(
            '-Operation','Create', '-TenantId',$DummyGuid, '-ClientId',$DummyGuid, '-ClientSecret','x',
            '-DisplayName','TestApp', '-SignOnUrl','https://ejemplo.com')
        $r.ExitCode | Should -Be 1; $r.Json.success | Should -BeFalse; $r.Json.message | Should -BeLike '*SignOnUrl*'
    }
}
