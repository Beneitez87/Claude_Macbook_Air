# ──────────────────────────────────────────────────────────────────────────
# Tests del aprovisionador Install-GraphPrerequisites.ps1.
# Pester 5.x
# ──────────────────────────────────────────────────────────────────────────

BeforeAll {
    . $PSScriptRoot/_TestHelpers.ps1
    $ProvisionPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'Install-GraphPrerequisites.ps1'
}

Describe 'Provision :: -CheckOnly (fichero real)' {
    It 'emite el contrato JSON y lista los 5 módulos de Graph' {
        $r = Invoke-RealScript -Path $ProvisionPath -ScriptArgs @('-CheckOnly')
        $r.Json.PSObject.Properties.Name | Should -Contain 'success'
        $r.Json.PSObject.Properties.Name | Should -Contain 'message'
        $r.Json.PSObject.Properties.Name | Should -Contain 'timestamp'
        $r.Json.PSObject.Properties.Name | Should -Contain 'data'
        $r.Json.data.modules.Count       | Should -Be 5
        $r.Json.data.checkOnly           | Should -BeTrue
        # Formato del timestamp sobre el JSON crudo (lo que recibe ServiceNow):
        $r.Stdout | Should -Match '"timestamp":"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z"'
    }
    It 'devuelve éxito y exit 0 cuando todos los módulos están presentes' {
        $r = Invoke-RealScript -Path $ProvisionPath -ScriptArgs @('-CheckOnly')
        $r.Json.success | Should -BeTrue
        $r.ExitCode     | Should -Be 0
    }
}
