# DnsClientX review environment

- This repository contains review tooling only. Never copy upstream product source into this checkout.
- The upstream review target is locked in `config/upstream.json`. `Get-UpstreamSource.ps1` must fail on any tag or commit mismatch; never fall back to `main`.
- Use PowerShell 7 for automation. `bootstrap/bootstrap.sh` is only the minimal no-PowerShell bootstrap.
- Keep SDK, PowerShell, NuGet cache, logs, and upstream checkout outside this repository where practical.
- Do not commit build outputs, package caches, test results, logs, or upstream sources.
- Do not run public DNS updates, AXFR scans, or load/benchmark tests as routine environment checks.
- Report full-suite and environment-limited test outcomes separately, including every excluded test name.
- Do not commit or push unless explicitly requested for the current task.
