# Export one completed Quest Ego recording over USB/ADB, verify every byte,
# then remove only that verified session from the Quest.

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$QuestRoot,

    [Parameter(Mandatory = $true)]
    [string]$SessionId,

    [string]$OutputRoot = (Join-Path (Get-Location).Path "tmp_data\quest"),
    [string]$Serial = "",
    [string]$AdbPath = "adb",
    [switch]$Yes
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Step {
    param([string]$Message)
    Write-Host "-> $Message" -ForegroundColor Cyan
}

function Write-Success {
    param([string]$Message)
    Write-Host "OK: $Message" -ForegroundColor Green
}

function Assert-SafeArguments {
    $script:QuestRoot = $script:QuestRoot.TrimEnd([char[]]@('/'))

    if (-not $script:QuestRoot.StartsWith("/")) {
        throw "-QuestRoot must be an absolute Quest path"
    }
    if ($script:QuestRoot -notmatch '^/[A-Za-z0-9._/-]+$') {
        throw "-QuestRoot contains unsupported characters"
    }
    $unsafeSegments = @($script:QuestRoot.Split("/") | Where-Object { $_ -eq "." -or $_ -eq ".." })
    if ($unsafeSegments.Count -gt 0) {
        throw "-QuestRoot must not contain . or .. path components"
    }
    if ($script:QuestRoot -in @("/", "/sdcard", "/storage", "/storage/emulated", "/storage/emulated/0")) {
        throw "Refusing unsafe or overly broad Quest root: $script:QuestRoot"
    }
    if (-not ($script:QuestRoot.StartsWith("/sdcard/") -or $script:QuestRoot.StartsWith("/storage/"))) {
        throw "-QuestRoot must be below /sdcard or /storage"
    }
    if ($script:SessionId -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$' -or $script:SessionId -in @(".", "..")) {
        throw "-SessionId may contain only letters, digits, dot, underscore, and dash"
    }
    if ([string]::IsNullOrWhiteSpace($script:OutputRoot)) {
        throw "-OutputRoot cannot be empty"
    }
}

function Get-AdbPrefix {
    if ([string]::IsNullOrWhiteSpace($script:Serial)) {
        return @()
    }
    return @("-s", $script:Serial)
}

function Invoke-AdbCapture {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)

    $allArguments = @((Get-AdbPrefix) + $Arguments)
    $output = @(& $script:AdbPath @allArguments 2>&1)
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        $detail = ($output | ForEach-Object { $_.ToString() }) -join [Environment]::NewLine
        throw "adb command failed ($exitCode): adb $($allArguments -join ' ')`n$detail"
    }
    return @($output | ForEach-Object { $_.ToString().TrimEnd("`r") })
}

function Test-AdbCommand {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)

    $allArguments = @((Get-AdbPrefix) + $Arguments)
    $null = & $script:AdbPath @allArguments 2>&1
    return $LASTEXITCODE -eq 0
}

function Select-AdbDevice {
    if (-not [string]::IsNullOrWhiteSpace($script:Serial)) {
        $state = (Invoke-AdbCapture -Arguments @("get-state") | Select-Object -First 1).Trim()
        if ($state -ne "device") {
            throw "ADB device is not ready: $script:Serial ($state)"
        }
        return
    }

    $deviceOutput = @(& $script:AdbPath devices 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "adb devices failed: $($deviceOutput -join [Environment]::NewLine)"
    }

    $rows = @()
    foreach ($lineValue in $deviceOutput) {
        $line = $lineValue.ToString().Trim()
        if ($line -match '^(\S+)\s+(device|unauthorized|offline|no permissions)\b') {
            $rows += [PSCustomObject]@{ Serial = $Matches[1]; State = $Matches[2] }
        }
    }
    if ($rows.Count -ne 1) {
        & $script:AdbPath devices -l
        throw "Expected exactly one ADB device; connect one Quest or pass -Serial"
    }
    if ($rows[0].State -ne "device") {
        throw "ADB device $($rows[0].Serial) is $($rows[0].State); authorize it in the headset"
    }
    $script:Serial = $rows[0].Serial
}

function Get-RemoteFileHash {
    param([Parameter(Mandatory = $true)][string]$RemotePath)

    $line = Invoke-AdbCapture -Arguments @("shell", "sha256sum", $RemotePath) | Select-Object -First 1
    if ($line -notmatch '^([A-Fa-f0-9]{64})\s+') {
        throw "Could not parse Quest SHA-256 for $RemotePath`: $line"
    }
    return $Matches[1].ToLowerInvariant()
}

function Normalize-ChecksumManifest {
    param([Parameter(Mandatory = $true)][object[]]$Lines)

    $normalized = @()
    foreach ($lineValue in $Lines) {
        $line = $lineValue.ToString().TrimEnd("`r")
        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }
        if ($line -notmatch '^([A-Fa-f0-9]{64})\s+\*?(.+)$') {
            throw "Could not parse Quest sidecar checksum line: $line"
        }
        $path = $Matches[2].Replace("\", "/")
        $normalized += "$($Matches[1].ToLowerInvariant())  $path"
    }
    return @($normalized | Sort-Object)
}

function Get-RemoteSidecarManifest {
    $command = "cd '$script:RemoteSidecars' && find . -type f -exec sha256sum '{}' ';' | LC_ALL=C sort"
    return @(Normalize-ChecksumManifest -Lines (Invoke-AdbCapture -Arguments @("shell", $command)))
}

function Get-LocalSidecarManifest {
    param([Parameter(Mandatory = $true)][string]$SidecarsPath)

    $root = [IO.Path]::GetFullPath($SidecarsPath).TrimEnd([char[]]@('\', '/'))
    $prefixLength = $root.Length + 1
    $lines = @()
    foreach ($file in Get-ChildItem -LiteralPath $root -File -Recurse) {
        $relative = $file.FullName.Substring($prefixLength).Replace("\", "/")
        $hash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        $lines += "$hash  ./$relative"
    }
    return @($lines | Sort-Object)
}

function Assert-SameManifest {
    param(
        [Parameter(Mandatory = $true)][object[]]$Expected,
        [Parameter(Mandatory = $true)][object[]]$Actual,
        [Parameter(Mandatory = $true)][string]$ErrorMessage
    )

    if ($Expected.Count -ne $Actual.Count) {
        throw "$ErrorMessage (file count $($Expected.Count) != $($Actual.Count))"
    }
    $difference = @(Compare-Object -ReferenceObject $Expected -DifferenceObject $Actual -SyncWindow 0)
    if ($difference.Count -gt 0) {
        throw $ErrorMessage
    }
}

function Invoke-Main {
    Assert-SafeArguments

    if ($null -eq (Get-Command $script:AdbPath -ErrorAction SilentlyContinue)) {
        throw "adb not found: $script:AdbPath"
    }

    Select-AdbDevice
    if (-not (Test-AdbCommand -Arguments @("shell", "command", "-v", "sha256sum"))) {
        throw "sha256sum is unavailable on the Quest; refusing an unverifiable export"
    }

    $script:RemoteMp4 = "$script:QuestRoot/$script:SessionId.mp4"
    $script:RemoteSidecars = "$script:QuestRoot/$script:SessionId"
    $script:RemoteManifest = "$script:RemoteSidecars/manifest.json"

    if (-not (Test-AdbCommand -Arguments @("shell", "test", "-f", $script:RemoteMp4))) {
        throw "MP4 not found on Quest: $script:RemoteMp4"
    }
    if (-not (Test-AdbCommand -Arguments @("shell", "test", "-d", $script:RemoteSidecars))) {
        throw "Sidecar directory not found on Quest: $script:RemoteSidecars"
    }
    if (-not (Test-AdbCommand -Arguments @("shell", "test", "-f", $script:RemoteManifest))) {
        throw "manifest.json not found on Quest: $script:RemoteManifest"
    }

    Write-Host "Quest device:   $script:Serial"
    Write-Host "Quest MP4:      $script:RemoteMp4"
    Write-Host "Quest sidecars: $script:RemoteSidecars"
    Write-Host "Computer root:  $script:OutputRoot"
    Write-Host "After verification, only the MP4 and sidecar directory shown above will be deleted from the Quest."

    if (-not $Yes) {
        $confirmation = Read-Host "Type the session id ($script:SessionId) to confirm export and post-verification deletion"
        if ($confirmation -cne $script:SessionId) {
            throw "Confirmation did not match; nothing was copied or deleted"
        }
    }

    $outputRootFull = [IO.Path]::GetFullPath($script:OutputRoot)
    $null = New-Item -ItemType Directory -Force -Path $outputRootFull
    $destination = Join-Path $outputRootFull $script:SessionId
    if (Test-Path -LiteralPath $destination) {
        throw "Destination already exists; refusing to overwrite: $destination"
    }

    $staging = Join-Path $outputRootFull ".$($script:SessionId).partial.$PID"
    if (Test-Path -LiteralPath $staging) {
        throw "Staging path already exists: $staging"
    }
    $null = New-Item -ItemType Directory -Path $staging

    try {
        Write-Step "Snapshotting Quest checksums before copy"
        $remoteMediaHashBefore = Get-RemoteFileHash -RemotePath $script:RemoteMp4
        $remoteSidecarsBefore = @(Get-RemoteSidecarManifest)
        if ($remoteSidecarsBefore.Count -eq 0) {
            throw "Sidecar directory contains no files"
        }

        Write-Step "Copying MP4"
        Invoke-AdbCapture -Arguments @("pull", $script:RemoteMp4, (Join-Path $staging "media.mp4")) |
            ForEach-Object { Write-Host $_ }

        Write-Step "Copying all sidecars"
        Invoke-AdbCapture -Arguments @("pull", $script:RemoteSidecars, (Join-Path $staging "sidecars")) |
            ForEach-Object { Write-Host $_ }

        $localMp4 = Join-Path $staging "media.mp4"
        $localSidecars = Join-Path $staging "sidecars"
        $localSidecarManifest = Join-Path $localSidecars "manifest.json"
        if (-not (Test-Path -LiteralPath $localMp4 -PathType Leaf) -or (Get-Item -LiteralPath $localMp4).Length -le 0) {
            throw "Copied MP4 is missing or empty"
        }
        if (-not (Test-Path -LiteralPath $localSidecarManifest -PathType Leaf)) {
            throw "Copied sidecars do not contain manifest.json"
        }

        try {
            $null = Get-Content -LiteralPath $localSidecarManifest -Raw -Encoding UTF8 | ConvertFrom-Json
        }
        catch {
            throw "Copied manifest.json is not valid JSON: $($_.Exception.Message)"
        }

        $localSidecarsManifest = @(Get-LocalSidecarManifest -SidecarsPath $localSidecars)
        $remoteSidecarsAfter = @(Get-RemoteSidecarManifest)
        $remoteMediaHashAfter = Get-RemoteFileHash -RemotePath $script:RemoteMp4
        $localMediaHash = (Get-FileHash -LiteralPath $localMp4 -Algorithm SHA256).Hash.ToLowerInvariant()

        if ($remoteMediaHashBefore -cne $remoteMediaHashAfter) {
            throw "Quest MP4 changed during copy; device data was not deleted"
        }
        if ($remoteMediaHashBefore -cne $localMediaHash) {
            throw "Copied MP4 checksum mismatch; device data was not deleted"
        }
        Assert-SameManifest -Expected $remoteSidecarsBefore -Actual $remoteSidecarsAfter `
            -ErrorMessage "Quest sidecars changed during copy; device data was not deleted"
        Assert-SameManifest -Expected $remoteSidecarsBefore -Actual $localSidecarsManifest `
            -ErrorMessage "Copied sidecar checksum mismatch; device data was not deleted"

        $topLevelManifest = Join-Path $staging "manifest.json"
        Copy-Item -LiteralPath $localSidecarManifest -Destination $topLevelManifest
        $sourceManifestHash = (Get-FileHash -LiteralPath $localSidecarManifest -Algorithm SHA256).Hash
        $topLevelManifestHash = (Get-FileHash -LiteralPath $topLevelManifest -Algorithm SHA256).Hash
        if ($sourceManifestHash -cne $topLevelManifestHash) {
            throw "Top-level manifest copy failed; device data was not deleted"
        }

        Move-Item -LiteralPath $staging -Destination $destination
        $staging = $null
        Write-Success "Verified MP4, valid manifest.json, and $($remoteSidecarsBefore.Count) sidecar files"
        Write-Success "Saved export to $destination"

        Write-Step "Deleting the verified session from the Quest"
        $null = Invoke-AdbCapture -Arguments @("shell", "rm", "-f", $script:RemoteMp4)
        $null = Invoke-AdbCapture -Arguments @("shell", "rm", "-rf", $script:RemoteSidecars)

        if (Test-AdbCommand -Arguments @("shell", "test", "-e", $script:RemoteMp4)) {
            throw "Local export is safe, but Quest MP4 deletion failed: $script:RemoteMp4"
        }
        if (Test-AdbCommand -Arguments @("shell", "test", "-e", $script:RemoteSidecars)) {
            throw "Local export is safe, but Quest sidecar deletion failed: $script:RemoteSidecars"
        }

        Write-Success "Removed the verified Quest MP4 and sidecars"
        Write-Host ""
        Write-Host "Export complete:"
        Write-Host "  $(Join-Path $destination 'media.mp4')"
        Write-Host "  $(Join-Path $destination 'manifest.json')"
        Write-Host "  $(Join-Path $destination 'sidecars')"
    }
    finally {
        if ($null -ne $staging -and (Test-Path -LiteralPath $staging)) {
            $expectedPrefix = ".$($script:SessionId).partial."
            if ((Split-Path -Leaf $staging).StartsWith($expectedPrefix)) {
                Remove-Item -LiteralPath $staging -Recurse -Force
            }
        }
    }
}

try {
    Invoke-Main
}
catch {
    [Console]::Error.WriteLine("ERROR: $($_.Exception.Message)")
    exit 1
}
