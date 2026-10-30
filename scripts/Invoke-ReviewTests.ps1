[CmdletBinding()]
param(
    [string] $RepositoryRoot = (Split-Path -Parent $PSScriptRoot),
    [string] $UpstreamPath,
    [string] $ResultsDirectory = (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'DnsClientX-review-results')
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$config = Get-Content -Raw -LiteralPath (Join-Path $RepositoryRoot 'config/upstream.json') | ConvertFrom-Json
if (-not $UpstreamPath) { $UpstreamPath = Join-Path (Split-Path -Parent $RepositoryRoot) $config.installRootName }
$dotnet = if ($env:DOTNET_ROOT) { Join-Path $env:DOTNET_ROOT $(if ($IsWindows) { 'dotnet.exe' } else { 'dotnet' }) } else { 'dotnet' }
[void][IO.Directory]::CreateDirectory($ResultsDirectory)
$runId = [guid]::NewGuid().ToString('N')
$trxPath = Join-Path $ResultsDirectory "full-$runId.trx"
$reportPath = Join-Path $ResultsDirectory "review-test-results-$runId.json"
$reportTempPath = "$reportPath.tmp"
$records = [Collections.Generic.List[object]]::new()
$testStartedUtc = [DateTime]::UtcNow
$result = $null

function Save-ReviewReport {
    param([object] $Value)
    $Value | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $reportTempPath -Encoding utf8
    Move-Item -LiteralPath $reportTempPath -Destination $reportPath -Force
}

function Invoke-DotNet {
    param(
        [string[]] $Arguments,
        [string] $Name,
        [switch] $AllowNonZero
    )
    & $script:dotnet @Arguments | Out-Host
    $code = $LASTEXITCODE
    $script:records.Add([pscustomobject]@{ Step = $Name; ExitCode = $code })
    if ($code -ne 0 -and -not $AllowNonZero) { throw "$Name failed with exit code $code" }
    return $code
}

try {
    if (-not (Test-Path -LiteralPath $UpstreamPath -PathType Container)) { throw "Upstream checkout does not exist: $UpstreamPath" }

    Push-Location $UpstreamPath
    try {
        [void](Invoke-DotNet @('restore', 'DnsClientX.sln', '-m:1') 'Restore')
        [void](Invoke-DotNet @('build', 'DnsClientX.sln', '-c', 'Release', '--no-restore', '-m:1') 'ReleaseBuild')

        $testExitCode = Invoke-DotNet @(
            'test', 'DnsClientX.Tests/DnsClientX.Tests.csproj', '-c', 'Release', '-f', 'net8.0',
            '--no-build', '--no-restore', '-m:1', '--logger', "trx;LogFileName=$trxPath"
        ) 'FullTests' -AllowNonZero
        if (-not (Test-Path -LiteralPath $trxPath -PathType Leaf)) { throw "This run did not produce its unique TRX file: $trxPath" }
        if ((Get-Item -LiteralPath $trxPath).LastWriteTimeUtc -lt $testStartedUtc.AddSeconds(-2)) { throw 'TRX timestamp predates this test run' }

        [xml]$trx = Get-Content -Raw -LiteralPath $trxPath
        $namespace = [Xml.XmlNamespaceManager]::new($trx.NameTable)
        $namespace.AddNamespace('t', 'http://microsoft.com/schemas/VisualStudio/TeamTest/2010')
        $resultNodes = @($trx.SelectNodes('//t:UnitTestResult', $namespace))
        if ($resultNodes.Count -eq 0) { throw 'TRX contains no test result identities' }

        $testCases = @(
            foreach ($node in $resultNodes) {
                $name = $node.GetAttribute('testName')
                $id = $node.GetAttribute('testId')
                $outcome = $node.GetAttribute('outcome')
                if ([string]::IsNullOrWhiteSpace($name) -or [string]::IsNullOrWhiteSpace($id) -or [string]::IsNullOrWhiteSpace($outcome)) {
                    throw 'TRX contains a result without testName, testId, or outcome'
                }
                $messageNode = $node.SelectSingleNode('.//t:ErrorInfo/t:Message', $namespace)
                $failureMessage = if ($messageNode) { ($messageNode.InnerText -replace '\s+', ' ').Trim() } else { $null }
                [pscustomobject]@{
                    TestId = $id
                    TestName = $name
                    Identity = "$id::$name"
                    Outcome = $outcome
                    FailureMessage = $failureMessage
                }
            }
        )
        $fullIdentitySet = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($testCase in $testCases) {
            if (-not $fullIdentitySet.Add($testCase.Identity)) { throw "Duplicate TRX test identity: $($testCase.Identity)" }
            if ($testCase.Outcome -cnotin @('Passed', 'Failed', 'NotExecuted')) { throw "Unsupported TRX outcome '$($testCase.Outcome)' for $($testCase.Identity)" }
        }

        $counters = $trx.TestRun.ResultSummary.Counters
        $total = [int]$counters.total
        $passed = [int]$counters.passed
        $failed = [int]$counters.failed
        $notExecuted = @($testCases | Where-Object { $_.Outcome -ceq 'NotExecuted' }).Count
        $actualFailed = @($testCases | Where-Object { $_.Outcome -ceq 'Failed' })
        if ($total -ne $testCases.Count -or $failed -ne $actualFailed.Count -or ($passed + $failed + $notExecuted) -ne $total) {
            throw 'TRX result rows do not reconcile with its summary counters'
        }

        $knownFailures = @($config.knownEnvironmentFailures)
        $knownSet = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($known in $knownFailures) {
            if (-not $known.testId -or -not $known.testName) { throw 'Every known failure must define a testId and exact testName' }
            $identity = "$($known.testId)::$($known.testName)"
            if (-not $knownSet.Add($identity)) { throw "Duplicate known failure identity in config: $identity" }
        }
        $knownMissing = @($knownSet | Where-Object { -not $fullIdentitySet.Contains($_) })
        if ($knownMissing.Count -gt 0) { throw "Known test identity missing from this run: $($knownMissing -join '; ')" }

        $actualFailedIdentities = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($case in $actualFailed) { [void]$actualFailedIdentities.Add($case.Identity) }
        $newFailures = @($actualFailed | Where-Object { -not $knownSet.Contains($_.Identity) })
        $knownActualFailed = @($actualFailed | Where-Object { $knownSet.Contains($_.Identity) })
        $recovered = @(
            foreach ($known in $knownFailures) {
                $identity = "$($known.testId)::$($known.testName)"
                if (@($testCases | Where-Object { $_.Identity -ceq $identity -and $_.Outcome -ceq 'Passed' }).Count -gt 0) { $identity }
            }
        )
        $knownSkipped = @(
            foreach ($known in $knownFailures) {
                $identity = "$($known.testId)::$($known.testName)"
                if (@($testCases | Where-Object { $_.Identity -ceq $identity -and $_.Outcome -ceq 'NotExecuted' }).Count -gt 0) { $identity }
            }
        )

        $comparableCases = @($testCases | Where-Object { -not ($_.Outcome -ceq 'Failed' -and $knownSet.Contains($_.Identity)) })
        $comparableIdentitySet = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($case in $comparableCases) { [void]$comparableIdentitySet.Add($case.Identity) }
        $expectedComparableIdentitySet = [Collections.Generic.HashSet[string]]::new($fullIdentitySet, [StringComparer]::Ordinal)
        foreach ($case in $knownActualFailed) {
            if (-not $expectedComparableIdentitySet.Remove($case.Identity)) { throw "Known failure was not present in full test identity set: $($case.Identity)" }
        }
        if (-not $comparableIdentitySet.SetEquals($expectedComparableIdentitySet)) {
            throw 'Full and environment-comparable test identity sets differ beyond exact known failing cases'
        }

        if ($testExitCode -eq 0 -and $actualFailed.Count -gt 0) { throw 'dotnet test reported success while TRX contains failures' }
        if ($testExitCode -ne 0 -and $actualFailed.Count -eq 0) { throw "dotnet test exited $testExitCode without a failed TRX test; this is an infrastructure failure" }

        $fullRun = [pscustomobject]@{
            Total = $total; Passed = $passed; Failed = $failed; Skipped = $notExecuted
            Identities = @($fullIdentitySet | Sort-Object -CaseSensitive)
        }
        $environmentComparable = [pscustomobject]@{
            Total = $comparableCases.Count
            Passed = @($comparableCases | Where-Object { $_.Outcome -ceq 'Passed' }).Count
            Failed = @($comparableCases | Where-Object { $_.Outcome -ceq 'Failed' }).Count
            Skipped = @($comparableCases | Where-Object { $_.Outcome -ceq 'NotExecuted' }).Count
            Identities = @($comparableIdentitySet | Sort-Object -CaseSensitive)
            ExcludedKnownFailures = @($knownActualFailed | ForEach-Object Identity | Sort-Object -CaseSensitive)
        }
        $result = [ordered]@{
            Status = if ($newFailures.Count -gt 0) { 'FailedNewTestFailures' } elseif ($actualFailed.Count -gt 0) { 'KnownEnvironmentFailuresOnly' } else { 'Passed' }
            RunId = $runId
            StartedUtc = $testStartedUtc
            CompletedUtc = [DateTime]::UtcNow
            Steps = $records
            TestSelection = 'Complete unfiltered test suite; known failures are classified after execution using exact TRX testId and testName identities.'
            DotNetFilterApplied = $false
            TestExitCode = $testExitCode
            FullSuite = $fullRun
            EnvironmentComparable = $environmentComparable
            KnownFailureCasesStillFailing = @($knownActualFailed | ForEach-Object Identity | Sort-Object -CaseSensitive)
            KnownFailureDetails = @($knownActualFailed | Select-Object Identity, FailureMessage)
            KnownFailureCasesRecovered = @($recovered | Sort-Object -CaseSensitive)
            KnownFailureCasesSkipped = @($knownSkipped | Sort-Object -CaseSensitive)
            NewFailures = @($newFailures | ForEach-Object Identity | Sort-Object -CaseSensitive)
            NewFailureDetails = @($newFailures | Select-Object Identity, FailureMessage)
            TrxPath = $trxPath
            ModuleCommands = @()
        }
        Save-ReviewReport -Value $result

        if ($newFailures.Count -gt 0) { throw "New test failures detected: $(($newFailures | ForEach-Object Identity) -join '; ')" }
        [void](Invoke-DotNet @('build', 'DnsClientX.PowerShell/DnsClientX.PowerShell.csproj', '-c', 'Debug', '-f', 'net8.0', '--no-restore', '-m:1') 'PowerShellModuleBuild')
        $moduleManifest = Join-Path $UpstreamPath 'Module/DnsClientX.psd1'
        Import-Module -Name $moduleManifest -Force -ErrorAction Stop
        try {
            $commands = @(Get-Command Resolve-Dns, Get-DnsService -ErrorAction Stop | ForEach-Object Name)
            if ($commands.Count -ne 2) { throw 'PowerShell module command check did not find both expected commands' }
        } finally {
            Remove-Module DnsClientX -ErrorAction SilentlyContinue
        }
        $records.Add([pscustomobject]@{ Step = 'PowerShellModuleImport'; ExitCode = 0 })
        $result['ModuleCommands'] = $commands
        $result['CompletedUtc'] = [DateTime]::UtcNow
        Save-ReviewReport -Value $result
    } finally {
        Pop-Location
    }
} catch {
    if ($null -eq $result) {
        $result = [ordered]@{
            Status = 'FailedBeforeTestClassification'
            RunId = $runId
            StartedUtc = $testStartedUtc
            CompletedUtc = [DateTime]::UtcNow
            Steps = $records
            TrxPath = if (Test-Path -LiteralPath $trxPath) { $trxPath } else { $null }
            Error = $_.Exception.Message
        }
    } else {
        $result['Status'] = 'Failed'
        $result['Error'] = $_.Exception.Message
        $result['CompletedUtc'] = [DateTime]::UtcNow
        $result['Steps'] = $records
    }
    try { Save-ReviewReport -Value $result } catch { Write-Warning "Could not save structured run report: $($_.Exception.Message)" }
    throw
}

[pscustomobject]$result
