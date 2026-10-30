[CmdletBinding()]
param([string] $RepositoryRoot = (Split-Path -Parent $PSScriptRoot), [string] $UpstreamPath, [switch] $CheckIdempotency)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$configPath = Join-Path $RepositoryRoot 'config/upstream.json'
$config = Get-Content -Raw -LiteralPath $configPath | ConvertFrom-Json
$initialize = Join-Path $PSScriptRoot 'Initialize-ReviewEnvironment.ps1'
$sourceScript = Join-Path $PSScriptRoot 'Get-UpstreamSource.ps1'
$before = & $initialize -RepositoryRoot $RepositoryRoot
$source = & $sourceScript -RepositoryRoot $RepositoryRoot -Destination $UpstreamPath
$second = $null
if ($CheckIdempotency) {
    $second = & $initialize -RepositoryRoot $RepositoryRoot
    $sourceAgain = & $sourceScript -RepositoryRoot $RepositoryRoot -Destination $UpstreamPath
    if ($sourceAgain.Commit -cne $config.commit) { throw 'Second initialization changed upstream SHA' }
}
$dotnet = Join-Path $env:DOTNET_ROOT $(if ($IsWindows) {'dotnet.exe'} else {'dotnet'})
$dotnetInfo = & $dotnet --info
if ($LASTEXITCODE -ne 0) { throw "dotnet --info failed: $LASTEXITCODE" }
$gitVersion = & git --version
if ($LASTEXITCODE -ne 0) { throw "git --version failed: $LASTEXITCODE" }
[pscustomobject]@{ OS = [Runtime.InteropServices.RuntimeInformation]::OSDescription; Architecture = [Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString(); Initialization = $before; SecondInitialization = $second; Upstream = $source; Git = $gitVersion; DotNetInfo = $dotnetInfo; EnvironmentVariables = [pscustomobject]@{ HOME=$env:HOME; DOTNET_ROOT=$env:DOTNET_ROOT; DOTNET_CLI_HOME=$env:DOTNET_CLI_HOME; NUGET_PACKAGES=$env:NUGET_PACKAGES; TMPDIR=$env:TMPDIR; TEMP=$env:TEMP; TMP=$env:TMP; PATH=$env:PATH } }
