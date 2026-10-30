[CmdletBinding()]
param(
    [switch] $InstallMissing,
    [string] $RepositoryRoot = (Split-Path -Parent $PSScriptRoot)
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Assert-ExitCode {
    param([string] $Command, [int] $ExitCode)
    if ($ExitCode -ne 0) { throw "$Command failed with exit code $ExitCode" }
}

$configPath = Join-Path $RepositoryRoot 'config/upstream.json'
$config = Get-Content -Raw -LiteralPath $configPath | ConvertFrom-Json
$root = if ($env:CODEX_WORKSPACE) { $env:CODEX_WORKSPACE } else { Split-Path -Parent $RepositoryRoot }
$toolRoot = Join-Path $root '.review-tools'
$dotnetRoot = if ($env:DOTNET_ROOT) { $env:DOTNET_ROOT } else { Join-Path $toolRoot 'dotnet' }
$cliHome = Join-Path $toolRoot 'cli-home'
$nugetPackages = Join-Path $toolRoot 'nuget/packages'
$tempRoot = Join-Path $toolRoot 'tmp'
$dotnetInstallParent = Split-Path -Parent $dotnetRoot
if ([string]::IsNullOrWhiteSpace($dotnetInstallParent)) { throw "Could not resolve parent directory for DOTNET_ROOT: $dotnetRoot" }
[void][IO.Directory]::CreateDirectory($dotnetInstallParent)
if (-not (Test-Path -LiteralPath $dotnetRoot)) {
    $dotnetLeaf = Split-Path -Leaf $dotnetRoot
    $orphanBackups = @(Get-ChildItem -LiteralPath $dotnetInstallParent -Directory -Filter "$dotnetLeaf.backup-*" -ErrorAction Stop)
    if ($orphanBackups.Count -gt 1) { throw "Multiple orphaned .NET installation backups found under $dotnetInstallParent; preserving them for manual recovery" }
    if ($orphanBackups.Count -eq 1) {
        [IO.Directory]::Move($orphanBackups[0].FullName, $dotnetRoot)
        Write-Warning "Recovered .NET installation root from interrupted transaction backup $($orphanBackups[0].Name)"
    }
}
foreach ($path in @($toolRoot, $cliHome, $nugetPackages, $tempRoot, $dotnetRoot)) {
    [void][IO.Directory]::CreateDirectory($path)
    $probe = Join-Path $path ([guid]::NewGuid().ToString('N'))
    [IO.File]::WriteAllText($probe, 'write-check')
    [IO.File]::Delete($probe)
}
$env:DOTNET_ROOT = $dotnetRoot
$env:DOTNET_CLI_HOME = $cliHome
$env:NUGET_PACKAGES = $nugetPackages
$env:TMPDIR = $tempRoot
$env:TEMP = $tempRoot
$env:TMP = $tempRoot
$env:HOME = $cliHome
$env:PATH = "$dotnetRoot$([IO.Path]::PathSeparator)$PSHOME$([IO.Path]::PathSeparator)$env:PATH"

function Install-DotNetSdk {
    param([string] $Version, [string] $InstallDir)
    $metadataUri = "https://builds.dotnet.microsoft.com/dotnet/release-metadata/$($Version.Split('.')[0]).0/releases.json"
    $metadata = Invoke-RestMethod -Uri $metadataUri
    $release = $metadata.releases | Where-Object { $_.sdk.version -eq $Version } | Select-Object -First 1
    if (-not $release) { throw "SDK $Version not found in official release metadata" }
    $architecture = [Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture.ToString().ToLowerInvariant()
    $platform = if ($IsWindows) { 'win' } elseif ($IsMacOS) { 'osx' } else { 'linux' }
    $extension = if ($IsWindows) { 'zip' } else { 'tar.gz' }
    $metadataAssetName = "dotnet-sdk-$platform-$architecture.$extension"
    $asset = $release.sdk.files | Where-Object { $_.name -eq $metadataAssetName } | Select-Object -First 1
    if (-not $asset -or -not $asset.url -or -not $asset.hash) { throw "Official SDK archive $metadataAssetName or SHA-512 was not found" }
    $assetUri = [Uri]$asset.url
    if ($assetUri.Scheme -cne 'https') { throw "SDK archive URL must use HTTPS: $($assetUri.Scheme)" }
    $assetName = [IO.Path]::GetFileName($assetUri.AbsolutePath)
    $installParent = Split-Path -Parent $InstallDir
    [void][IO.Directory]::CreateDirectory($installParent)
    $transaction = Join-Path $installParent ".dotnet-$Version-$([guid]::NewGuid().ToString('N'))"
    $payload = Join-Path $transaction 'payload'
    $candidate = Join-Path $transaction 'candidate'
    $backup = "$InstallDir.backup-$([guid]::NewGuid().ToString('N'))"
    $archive = Join-Path $transaction $assetName
    $tarPath = Join-Path $transaction "dotnet-sdk-$Version.tar"
    $targetMoved = $false
    $candidateCommitted = $false
    $priorVersions = @()

    try {
        [void][IO.Directory]::CreateDirectory($payload)
        [void][IO.Directory]::CreateDirectory($candidate)
        if (Test-Path -LiteralPath $InstallDir) {
            $existingDotnet = Join-Path $InstallDir $(if ($IsWindows) { 'dotnet.exe' } else { 'dotnet' })
            if (Test-Path -LiteralPath $existingDotnet) {
                $priorVersions = @(& $existingDotnet --list-sdks)
                if ($LASTEXITCODE -ne 0) { throw "Existing dotnet --list-sdks failed with exit code $LASTEXITCODE" }
            }
            Get-ChildItem -LiteralPath $InstallDir -Force | ForEach-Object {
                Copy-Item -LiteralPath $_.FullName -Destination $candidate -Recurse -Force
                if (-not $?) { throw "Could not stage existing SDK file tree: $($_.FullName)" }
            }
        }

        Invoke-WebRequest -Uri $asset.url -OutFile $archive
        if (-not (Test-Path -LiteralPath $archive) -or (Get-Item -LiteralPath $archive).Length -eq 0) {
            throw "SDK archive download was empty: $assetName"
        }
        $actualHash = (Get-FileHash -LiteralPath $archive -Algorithm SHA512).Hash
        if ($actualHash -ine $asset.hash) { throw "SDK $Version SHA-512 mismatch" }

        if ($IsWindows) {
            Expand-Archive -LiteralPath $archive -DestinationPath $payload
        } else {
            $inputStream = [IO.File]::OpenRead($archive)
            try {
                $gzip = [IO.Compression.GZipStream]::new($inputStream, [IO.Compression.CompressionMode]::Decompress)
                try {
                    $tarStream = [IO.File]::Create($tarPath)
                    try { $gzip.CopyTo($tarStream) } finally { $tarStream.Dispose() }
                } finally { $gzip.Dispose() }
            } finally { $inputStream.Dispose() }
            if (-not (Test-Path -LiteralPath $tarPath) -or (Get-Item -LiteralPath $tarPath).Length -eq 0) {
                throw "GZip extraction produced no tar payload for SDK $Version"
            }
            [System.Formats.Tar.TarFile]::ExtractToDirectory($tarPath, $payload, $true)
        }

        $payloadDotnet = Join-Path $payload $(if ($IsWindows) { 'dotnet.exe' } else { 'dotnet' })
        if (-not (Test-Path -LiteralPath $payloadDotnet)) { throw "Extracted SDK $Version has no dotnet host" }
        $payloadVersions = @(& $payloadDotnet --list-sdks)
        if ($LASTEXITCODE -ne 0 -or -not ($payloadVersions | Where-Object { $_ -match "^$([regex]::Escape($Version))\s" })) {
            throw "Extracted SDK payload did not register SDK $Version"
        }

        $payloadSdk = Join-Path $payload "sdk/$Version"
        if (-not (Test-Path -LiteralPath $payloadSdk -PathType Container)) { throw "Extracted SDK directory is missing: $payloadSdk" }
        foreach ($item in Get-ChildItem -LiteralPath $payload -Force) {
            if ($item.Name -eq 'sdk' -and $item.PSIsContainer) { continue }
            Copy-Item -LiteralPath $item.FullName -Destination $candidate -Recurse -Force
        }
        $candidateSdkRoot = Join-Path $candidate 'sdk'
        [void][IO.Directory]::CreateDirectory($candidateSdkRoot)
        foreach ($sdkItem in Get-ChildItem -LiteralPath (Join-Path $payload 'sdk') -Force) {
            if ($sdkItem.Name -eq $Version) { continue }
            Copy-Item -LiteralPath $sdkItem.FullName -Destination $candidateSdkRoot -Recurse -Force
        }
        $candidateSdk = Join-Path $candidateSdkRoot $Version
        if (Test-Path -LiteralPath $candidateSdk) { throw "Target already contains an incomplete SDK $Version directory; preserving it" }
        Move-Item -LiteralPath $payloadSdk -Destination $candidateSdk

        $candidateDotnet = Join-Path $candidate $(if ($IsWindows) { 'dotnet.exe' } else { 'dotnet' })
        $candidateVersions = @(& $candidateDotnet --list-sdks)
        if ($LASTEXITCODE -ne 0 -or -not ($candidateVersions | Where-Object { $_ -match "^$([regex]::Escape($Version))\s" })) {
            throw "Staged installation did not register SDK $Version"
        }
        foreach ($prior in $priorVersions) {
            $priorVersion = ($prior -split '\s+')[0]
            if (-not ($candidateVersions | Where-Object { $_ -match "^$([regex]::Escape($priorVersion))\s" })) {
                throw "Staging SDK $Version would drop existing SDK $priorVersion"
            }
        }

        if (Test-Path -LiteralPath $InstallDir) {
            [IO.Directory]::Move($InstallDir, $backup)
            $targetMoved = $true
        }
        [IO.Directory]::Move($candidate, $InstallDir)
        $candidateCommitted = $true
        $installedDotnet = Join-Path $InstallDir $(if ($IsWindows) { 'dotnet.exe' } else { 'dotnet' })
        $installedVersions = @(& $installedDotnet --list-sdks)
        if ($LASTEXITCODE -ne 0 -or -not ($installedVersions | Where-Object { $_ -match "^$([regex]::Escape($Version))\s" })) {
            throw "Committed SDK $Version did not pass --list-sdks verification"
        }
        foreach ($prior in $priorVersions) {
            $priorVersion = ($prior -split '\s+')[0]
            if (-not ($installedVersions | Where-Object { $_ -match "^$([regex]::Escape($priorVersion))\s" })) {
                throw "Committed SDK $Version lost existing SDK $priorVersion"
            }
        }
        $backupToRemove = if ($targetMoved) { $backup } else { $null }
        $targetMoved = $false
        $candidateCommitted = $false
        if ($backupToRemove -and (Test-Path -LiteralPath $backupToRemove)) {
            try { Remove-Item -LiteralPath $backupToRemove -Recurse -Force -ErrorAction Stop }
            catch { Write-Warning "SDK installation succeeded; prior SDK backup cleanup was incomplete at $backupToRemove" }
        }
    } catch {
        if ($candidateCommitted -and (Test-Path -LiteralPath $InstallDir)) {
            Remove-Item -LiteralPath $InstallDir -Recurse -Force
            $candidateCommitted = $false
        }
        if ($targetMoved -and (Test-Path -LiteralPath $backup) -and -not (Test-Path -LiteralPath $InstallDir)) {
            [IO.Directory]::Move($backup, $InstallDir)
            $targetMoved = $false
        }
        throw
    } finally {
        if (Test-Path -LiteralPath $transaction) {
            try { Remove-Item -LiteralPath $transaction -Recurse -Force -ErrorAction Stop }
            catch { Write-Warning "Could not remove SDK transaction directory $transaction" }
        }
        if ($targetMoved -and (Test-Path -LiteralPath $backup) -and -not (Test-Path -LiteralPath $InstallDir)) {
            [IO.Directory]::Move($backup, $InstallDir)
        }
    }
}

$dotnet = Join-Path $dotnetRoot $(if ($IsWindows) { 'dotnet.exe' } else { 'dotnet' })
$installedSdks = @()
if (Test-Path -LiteralPath $dotnet) { $installedSdks = @(& $dotnet --list-sdks); Assert-ExitCode 'dotnet --list-sdks' $LASTEXITCODE }
foreach ($required in $config.toolchain.dotnetSdks) {
    if (-not ($installedSdks | Where-Object { $_ -match "^$([regex]::Escape($required))\s" })) {
        if (-not $InstallMissing) { throw "Required .NET SDK $required is missing. Rerun with -InstallMissing; existing SDKs are preserved." }
        Install-DotNetSdk -Version $required -InstallDir $dotnetRoot
        $installedSdks = @(& $dotnet --list-sdks)
        Assert-ExitCode 'dotnet --list-sdks after installation' $LASTEXITCODE
        if (-not ($installedSdks | Where-Object { $_ -match "^$([regex]::Escape($required))\s" })) { throw "SDK $required was not registered after extraction" }
    }
}
$pwshVersion = $PSVersionTable.PSVersion.ToString()
if ($pwshVersion -ne $config.toolchain.powershell) {
    throw "PowerShell $($config.toolchain.powershell) required; found $pwshVersion"
}
[pscustomobject]@{
    Status = 'Ready'
    PowerShell = $pwshVersion
    DotNetSdks = $installedSdks
    DotNetRoot = $dotnetRoot
    CliHome = $cliHome
    NuGetPackages = $nugetPackages
    TempRoot = $tempRoot
}
