$ErrorActionPreference = "Stop"
Set-Location (Join-Path $PSScriptRoot "..\..")

python -m venv .build-venv
& .\.build-venv\Scripts\python.exe -m pip install --upgrade pip pyinstaller .
& .\.build-venv\Scripts\pyinstaller.exe --clean --noconfirm packaging\operator-collector.spec

$iscc = Get-Command ISCC.exe -ErrorAction SilentlyContinue
if ($null -eq $iscc) {
    Write-Host "Built dist\operator-collector.exe"
    Write-Host "Install Inno Setup and rerun to create the signed installer shell."
    exit 0
}

& $iscc.Source packaging\windows\operator-collector.iss
Write-Host "Built installer under dist\installers"
