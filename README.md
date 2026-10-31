DnsClientX Review

Independent technical assessment of "EvotecIT/DnsClientX" (https://github.com/EvotecIT/DnsClientX).

Purpose

- Evaluate DNS protocol correctness and RFC conformance.
- Review security, reliability, and error handling.
- Assess the PowerShell 7 module and cross-platform behavior.
- Validate platform-specific behavior on Windows.
- Track findings and regressions across upstream releases.

Repository Policy

This repository contains assessment documents, reproducible tests, and review tooling.

The upstream DnsClientX source code is maintained separately and must be checked out at an explicitly recorded Git commit.

Initial activities are read-only. Changes to upstream source are not permitted unless specifically authorized.

Current Status

Environment bootstrap pending. No source version has been approved or audited.

Codex Cloud startup

PowerShell in Codex Cloud must be started through the repository bootstrap. Do not invoke `pwsh` directly: the bootstrap selects writable paths under `/workspace`, checks them, adds the pinned PowerShell and .NET directories to its child `PATH`, and then validates the pinned PowerShell version.

From the review repository root, start a PowerShell command with:

```sh
./bootstrap/bootstrap.sh -NoLogo -NoProfile -File scripts/Test-ReviewEnvironment.ps1
```

Cloud Start instructions should require this bootstrap for every task that needs PowerShell. The Cloud Install script should not invoke `pwsh` directly; the bootstrap handles an existing installation and installs the pinned release when it is missing.
