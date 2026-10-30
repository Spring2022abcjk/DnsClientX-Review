[CmdletBinding()]
param(
    [string] $RepositoryRoot = (Split-Path -Parent $PSScriptRoot),
    [string] $UpstreamPath,
    [string] $ResultsDirectory = (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'DnsClientX-review-results'),
    [switch] $IncludeFullSuite
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$config = Get-Content -Raw -LiteralPath (Join-Path $RepositoryRoot 'config/upstream.json') | ConvertFrom-Json
if (-not $UpstreamPath) { $UpstreamPath = Join-Path (Split-Path -Parent $RepositoryRoot) $config.installRootName }
$dotnet = if ($env:DOTNET_ROOT) { Join-Path $env:DOTNET_ROOT $(if ($IsWindows) {'dotnet.exe'} else {'dotnet'}) } else { 'dotnet' }
$null = New-Item -ItemType Directory -Force -Path $ResultsDirectory
$records = [Collections.Generic.List[object]]::new()

function Invoke-DotNet {
    param([string[]] $Arguments, [string] $Name, [switch] $ExpectedFailure)
    & $script:dotnet @Arguments
    $code = $LASTEXITCODE
    $script:records.Add([pscustomobject]@{ Step = $Name; ExitCode = $code; ExpectedFailure = [bool]$ExpectedFailure })
    if ($code -ne 0 -and -not $ExpectedFailure) { throw "$Name failed with exit code $code" }
}

Push-Location $UpstreamPath
try {
    Invoke-DotNet @('restore','DnsClientX.sln','-m:1') 'Restore'
    Invoke-DotNet @('build','DnsClientX.sln','-c','Release','--no-restore','-m:1') 'ReleaseBuild'
    if ($IncludeFullSuite) {
        $trx = Join-Path $ResultsDirectory 'full.trx'
        Invoke-DotNet @('test','DnsClientX.Tests/DnsClientX.Tests.csproj','-c','Release','-f','net8.0','--no-build','--no-restore','-m:1','--logger',"trx;LogFileName=$trx") 'FullTests' -ExpectedFailure
    }
    $excluded = @($config.knownEnvironmentFailures)
    $selectors = @($excluded | ForEach-Object { $_ -replace '\(.*$', '' } | Select-Object -Unique)
    $filter = ($selectors | ForEach-Object { "FullyQualifiedName!~$_" }) -join '&'
    $trxFiltered = Join-Path $ResultsDirectory 'environment-limited.trx'
    Invoke-DotNet @('test','DnsClientX.Tests/DnsClientX.Tests.csproj','-c','Release','-f','net8.0','--no-build','--no-restore','-m:1','--filter',$filter,'--logger',"trx;LogFileName=$trxFiltered") 'EnvironmentLimitedTests'
    Invoke-DotNet @('build','DnsClientX.PowerShell/DnsClientX.PowerShell.csproj','-c','Debug','-f','net8.0','--no-restore','-m:1') 'PowerShellModuleBuild'
} finally { Pop-Location }

$summary = foreach ($path in @((Join-Path $ResultsDirectory 'full.trx'), (Join-Path $ResultsDirectory 'environment-limited.trx'))) {
    if (Test-Path $path) {
        [xml]$xml = Get-Content -Raw $path
        $c = $xml.TestRun.ResultSummary.Counters
        $ns = [Xml.XmlNamespaceManager]::new($xml.NameTable)
        $ns.AddNamespace('t', 'http://microsoft.com/schemas/VisualStudio/TeamTest/2010')
        $results = $xml.SelectNodes('//t:UnitTestResult', $ns)
        $skipped = @($results | Where-Object { $_.GetAttribute('outcome') -eq 'NotExecuted' }).Count
        [pscustomobject]@{ File = [IO.Path]::GetFileName($path); Total = [int]$c.total; Passed = [int]$c.passed; Failed = [int]$c.failed; Skipped = $skipped }
    }
}
$result = [pscustomobject]@{ TimestampUtc = [DateTime]::UtcNow; Steps = $records; Tests = @($summary); ExcludedTests = $excluded; ExcludedTestSelectors = $selectors }
$result | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $ResultsDirectory 'review-test-results.json')
$result
