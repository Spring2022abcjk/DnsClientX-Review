[CmdletBinding()]
param(
    [string] $RepositoryRoot = (Split-Path -Parent $PSScriptRoot),
    [string] $Destination
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$config = Get-Content -Raw -LiteralPath (Join-Path $RepositoryRoot 'config/upstream.json') | ConvertFrom-Json
$workspace = if ($env:CODEX_WORKSPACE) { $env:CODEX_WORKSPACE } else { Split-Path -Parent $RepositoryRoot }
if (-not $Destination) { $Destination = Join-Path $workspace $config.installRootName }

$repositoryPath = [IO.Path]::GetFullPath($RepositoryRoot).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
$destinationPath = [IO.Path]::GetFullPath($Destination).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
$pathComparison = if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
$repositoryPrefix = "$repositoryPath$([IO.Path]::DirectorySeparatorChar)"
if ($destinationPath.Equals($repositoryPath, $pathComparison) -or $destinationPath.StartsWith($repositoryPrefix, $pathComparison)) {
    throw "Upstream source destination must be outside the review repository: $destinationPath"
}

if (-not (Test-Path -LiteralPath (Join-Path $Destination '.git'))) {
    & git clone --no-checkout $config.repository $Destination
    if ($LASTEXITCODE -ne 0) { throw "git clone failed: $LASTEXITCODE" }
} else {
    $origin = & git -C $Destination remote get-url origin
    if ($LASTEXITCODE -ne 0 -or $origin.Trim() -ne $config.repository) { throw 'Existing upstream path has a different origin' }
    $changes = & git -C $Destination status --porcelain
    if ($LASTEXITCODE -ne 0 -or $changes) { throw 'Existing upstream checkout is not clean; preserving it and stopping' }
    & git -C $Destination fetch --tags origin
    if ($LASTEXITCODE -ne 0) { throw "git fetch failed: $LASTEXITCODE" }
}
$tagCommit = & git -C $Destination rev-parse "$($config.tag)^{commit}"
if ($LASTEXITCODE -ne 0) { throw "Unable to resolve tag $($config.tag)" }
if ($tagCommit.Trim() -cne $config.commit) { throw "Tag SHA mismatch: expected $($config.commit), got $($tagCommit.Trim())" }
& git -C $Destination checkout --detach $config.tag
if ($LASTEXITCODE -ne 0) { throw "git checkout failed: $LASTEXITCODE" }
$head = & git -C $Destination rev-parse HEAD
if ($LASTEXITCODE -ne 0 -or $head.Trim() -cne $config.commit) { throw "Checked out SHA mismatch: $($head.Trim())" }
[pscustomobject]@{ Repository = $config.repository; Tag = $config.tag; Commit = $head.Trim(); Path = $Destination }
