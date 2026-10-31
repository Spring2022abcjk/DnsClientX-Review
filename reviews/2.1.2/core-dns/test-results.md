# Test and reproduction record

## Environment and source identity

- Upstream acquisition used `bootstrap/bootstrap.sh` to invoke `scripts/Get-UpstreamSource.ps1` with destination `/workspace/DnsClientX-upstream`.
- The first clone attempt was blocked by the default sandbox proxy. Retrying the same script with network access succeeded; the script verified tag `DnsClientX-v2.1.2` at `1cfb438fd4c75a8ae54d457fb3073ab4aeb3718a` and checked out detached HEAD. `git status --porcelain` was empty after all build/test work.
- `scripts/Initialize-ReviewEnvironment.ps1 -InstallMissing`, `scripts/Test-ReviewEnvironment.ps1`, and `scripts/Invoke-ReviewTests.ps1` were each run through `bootstrap/bootstrap.sh`. The custom probe was also launched by a PowerShell `-Command` passed through the bootstrap.
- Environment check observed duplicate PATH entries: `/workspace/.review-tools/dotnet` appears twice and `/workspace/.powershell/7.6.9` appears twice. This was recorded only; no environment-management script was changed.
- Runtime: Debian GNU/Linux 13 x64, PowerShell 7.6.9, .NET SDKs 8.0.427 and 10.0.403.

## Full suite

Command used the repository runner without a test filter:

```text
./bootstrap/bootstrap.sh -NoLogo -NoProfile -File scripts/Invoke-ReviewTests.ps1 \
  -UpstreamPath /workspace/DnsClientX-upstream \
  -ResultsDirectory /workspace/DnsClientX-review-results
```

| Step | Result |
|---|---:|
| Solution restore | Passed |
| Release solution build | Passed, 0 warnings, 0 errors |
| Unfiltered `DnsClientX.Tests` on net8.0 | 1,341 passed, 0 failed, 58 skipped, 1,399 total |
| PowerShell module Debug/net8.0 build | Passed, 0 warnings, 0 errors |
| Module import and command check | Passed (`Resolve-Dns`, `Get-DnsService`) |
| Environment-comparable suite | 1,341 passed, 0 failed, 58 skipped; no exclusions |

The .NET library built for netstandard2.0, net8.0, and net10.0 as part of the solution build; the test runner executed the complete test project on net8.0. TRX: `/workspace/DnsClientX-review-results/full-37ac606ab23644d090631d31e4e702b1.trx`. Structured runner report: `/workspace/DnsClientX-review-results/review-test-results-37ac606ab23644d090631d31e4e702b1.json`.

All seven pre-existing environment-failure identities were still present in `config/upstream.json`. Each passed in this run; none was excluded, skipped, or counted as a new issue:

| Test ID | Exact test name | This run |
|---|---|---|
| `4b18e9fa-9ba1-58a0-d486-56ff15c62173` | `DnsClientX.Tests.AuditTrailTests.ShouldRecordResponseWhenEnabled` | Passed (recovered) |
| `b13a81fc-5243-041c-67e8-44942f2cda54` | `DnsClientX.Tests.CliIntegrationTests.CliRunsWithoutLeavingSockets` | Passed (recovered) |
| `27255b5e-73e2-04c0-82db-cf1f62d2e15c` | `DnsClientX.Tests.CliIntegrationTests.TypeOption_IsCaseInsensitive(option: "--type")` | Passed (recovered) |
| `5df0ed6b-c1d6-76df-06f2-106af592e0d1` | `DnsClientX.Tests.CliIntegrationTests.TypeOption_IsCaseInsensitive(option: "--TYPE")` | Passed (recovered) |
| `0b2ca754-03ef-1002-a62f-57a55b3d9eb0` | `DnsClientX.Tests.CliIntegrationTests.WirePostOption_Executes` | Passed (recovered) |
| `b41aa51e-e9f2-d187-1ac8-7e8f3dd5f497` | `DnsClientX.Tests.CliIntegrationTests.Cli_DisplaysRetryCount` | Passed (recovered) |
| `d219d873-0ed2-d409-c60d-292d16ff56b1` | `DnsClientX.Tests.DnsWireResolveUdpIPv6Tests.ResolveWireFormatUdp_ShouldReturnServerFailure_ForInvalidServer` | Passed (recovered) |

The 58 skipped cases included opt-in real-DNS/live-provider tests and platform-dependent integration tests. No public DNS update, external AXFR scan, load test, or benchmark was run. The full test project did exercise deterministic local mock-server update/transfer tests.

## Protocol-focused existing tests

These classes were included in the unfiltered passing suite:

- `DnsWireAdversarialCorpusTests`: short header, impossible section counts, reserved labels, forward/out-of-range pointer, truncated RR and trailing bytes.
- `DnsWireResponseValidationTests`: response QR/ID/Question matching, pointer loop, OPT section validation, EDNS extended RCODE and EDE.
- `DnsWireFallbackTests`: UDP TC fallback to TCP and fallback-disabled behavior.
- `DnsWireMessageParserTests`: EDNS payload parsing, compressed Questions, truncated pointer and OPT section checks.
- `DnsStreamConnectionPoolTests`, `DnsWireReadTimeoutTests`, `TcpCleanupRegressionTests`, `TcpDisposeCountTests`, `CancellationTests`: persistent connection framing/correlation, timeouts, cancellation and disposal.
- `DnsWireQueryClientTests`: local UDP diagnostic query round-trip and caller cancellation.

## Additional deterministic probes

An ephemeral console harness referenced the built upstream assembly. Packets and local servers were constructed in memory or bound only to loopback; no public DNS server was contacted. The harness was kept under `work/` and was not committed.

| Probe | Input | Observed result | Assessment |
|---|---|---|---|
| Oversized TCP body | Query with a 65,520-byte NSID option | Serialized body 65,564 bytes; TCP prefix 28; loopback server observed 65,536 bytes outside the declared frame | Reproduces F-01 |
| Out-of-range ECS | IPv4 `192.0.2.0/33` | Serialized as `00 01 21 00 C0 00 02 00`, no exception | Reproduces F-02 |
| EDNS helper label cap | 51 one-octet labels with OPT | Valid 130-byte DNS query; `TryParseEdns` returned false | Reproduces F-03 |
| Pointer into header | Response ID `0x00EF`, matching Question, answer owner `C0 00` | Full parser accepted; answer owner became `.` | Reproduces F-04 |
| Compression chain | Repeated A owners compressed to previous earlier occurrence | 128 hops accepted; 129 hops rejected as “loop detected” | Reproduces F-05 |
| Foreign UDP peer | Matching ID/Question response sent from a second loopback UDP socket | Connected query socket ignored it and timed out | Peer filtering behaved as expected |
| TCP short reads | Internal exact-read helper fed one byte per read | Read 4 bytes as `01020304` | Short reads handled |
| TCP early close | Exact-read helper asked for 2 bytes from a 1-byte stream | `EndOfStreamException` | Premature close detected |

## Verification limits

The full test suite is a regression result, not exhaustive protocol fuzzing. The additional harness covered the exact cases above only. Windows execution, the Windows ZIP installation path, and test execution on net10.0 were not performed in this review environment.
