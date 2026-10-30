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
    $rid = "$platform-$architecture"
    $extension = if ($IsWindows) { 'zip' } else { 'tar.gz' }
    $assetName = "dotnet-sdk-$Version-$rid.$extension"
    $asset = $release.sdk.files | Where-Object { $_.name -eq $assetName } | Select-Object -First 1
    if (-not $asset -or -not $asset.url -or -not $asset.hash) { throw "Official SDK archive $assetName or SHA-512 was not found" }
    $archive = Join-Path ([IO.Path]::GetTempPath()) $assetName
    Invoke-WebRequest -Uri $asset.url -OutFile $archive
    $actualHash = (Get-FileHash -LiteralPath $archive -Algorithm SHA512).Hash
    if ($actualHash -ine $asset.hash) { Remove-Item -LiteralPath $archive -Force; throw "SDK $Version SHA-512 mismatch" }
    [void][IO.Directory]::CreateDirectory($InstallDir)
    if ($IsWindows) { Expand-Archive -LiteralPath $archive -DestinationPath $InstallDir -Force }
    else { [System.Formats.Tar.TarFile]::ExtractToDirectory($archive, $InstallDir, $true) }
    Remove-Item -LiteralPath $archive -Force
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
