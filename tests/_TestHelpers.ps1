# ──────────────────────────────────────────────────────────────────────────
# Helpers compartidos por las suites de test del script unificado
# EnterpriseApp_Lifecycle.ps1.
#
# El script de producción es un "script con param()" que, al ejecutarse, se
# conecta a Microsoft Graph. Para probar su LÓGICA INTERNA sin tocar el tenant,
# extraemos el texto fuente de sus funciones mediante el AST y lo cargamos
# aislado en el scope de test. Las llamadas a cmdlets de Graph se sustituyen
# por mocks de Pester.
# ──────────────────────────────────────────────────────────────────────────

$RepoRoot   = Split-Path -Parent $PSScriptRoot
$ScriptPath = Join-Path $RepoRoot 'EnterpriseApp_Lifecycle.ps1'

# GUID de relleno válido para los tests que solo necesitan superar el
# chequeo de formato.
$DummyGuid = '11111111-1111-1111-1111-111111111111'

function Get-ScriptFunctionText {
    <#
    .SYNOPSIS
        Devuelve el texto fuente de las funciones indicadas (o de todas si no
        se especifica -Name) de un script, sin ejecutar su cuerpo.
    #>
    param(
        [Parameter(Mandatory)] [string]   $Path,
        [string[]] $Name
    )
    $ast = [System.Management.Automation.Language.Parser]::ParseFile(
        (Resolve-Path $Path).Path, [ref]$null, [ref]$null)

    $funcs = $ast.FindAll({
        param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst]
    }, $false)

    ($funcs |
        Where-Object { -not $Name -or $_.Name -in $Name } |
        ForEach-Object { $_.Extent.Text }) -join "`n`n"
}

function Invoke-RealScript {
    <#
    .SYNOPSIS
        Ejecuta el fichero .ps1 real en un proceso pwsh hijo y devuelve un
        objeto con { ExitCode, Stdout, Json }. Se usa para probar las puertas
        de validación que corren ANTES de cargar módulos / conectar a Graph,
        de modo que no se toca el tenant.
    #>
    param(
        [Parameter(Mandatory)] [string]   $Path,
        [Parameter(Mandatory)] [string[]] $ScriptArgs
    )
    $stdout = & pwsh -NoProfile -File $Path @ScriptArgs 2>$null
    $code   = $LASTEXITCODE
    $json   = $null
    if ($stdout) {
        $line = ($stdout | Where-Object { $_ -match '^\s*\{' } | Select-Object -Last 1)
        if ($line) { $json = $line | ConvertFrom-Json }
    }
    [pscustomobject]@{
        ExitCode = $code
        Stdout   = ($stdout -join "`n")
        Json     = $json
    }
}
