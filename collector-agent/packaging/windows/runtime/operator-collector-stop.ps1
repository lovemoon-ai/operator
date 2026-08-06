$ErrorActionPreference = "SilentlyContinue"
$processPaths = @(
    (Join-Path $PSScriptRoot "python.exe").ToLowerInvariant()
    (Join-Path $PSScriptRoot "operator-collector.exe").ToLowerInvariant()
)

Get-CimInstance Win32_Process |
    Where-Object { $_.ExecutablePath -and $processPaths -contains $_.ExecutablePath.ToLowerInvariant() } |
    ForEach-Object { Invoke-CimMethod -InputObject $_ -MethodName Terminate | Out-Null }
