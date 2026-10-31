# Open questions and review limits

These items were not promoted to confirmed findings because this pass did not establish their full protocol or impact boundary.

1. **Compression-chain resource policy.** F-05 reproduces rejection after 128 pointer hops. RFC 1035 §4.1.4 specifies prior offsets and expanded-name limits but no hop count. Confirm whether maintainers intend 128 as a deliberate parser resource limit; if so, document the limit and return a resource-limit diagnostic rather than reporting a loop.
2. **OPT root-name wire encoding.** The response parser checks the decoded OPT owner string for `.`. This pass did not establish whether RFC 6891 §6.1.2's requirement that NAME be the root label requires a literal zero octet rather than a pointer resolving to root. No finding is recorded for this edge case.
3. **Shared lightweight name skipper.** `TryContainsEdnsOption` uses the same 50-label `TrySkipName` helper as `TryParseEdns`; it is also used by DoQ code to inspect EDNS TCP Keepalive. The public EDNS helper limit is reproduced as F-03. The DoQ-specific effect and RFC 9250 obligations were not exercised in this UDP/TCP-focused pass.
4. **UDP maximum-size behavior.** Query construction and TCP framing boundaries were checked, but a full 65,535-octet UDP response was not sent through the runtime socket stack. The local source-filter test used a small datagram.
5. **Platform/framework matrix.** Tests ran on Linux x64 and net8.0. The solution build covered library targets netstandard2.0, net8.0, and net10.0, but tests were not executed on net10.0 or Windows. The repository's Windows ZIP install path remains unverified.

## Explicitly unreviewed in this pass

DoH/HTTP2/HTTP3/gRPC/QUIC envelopes, multicast behavior, DNSSEC validation, TSIG, dynamic UPDATE, AXFR/IXFR semantics, cache behavior, and deep per-record semantic validation were not audited. Local unit tests for some of these features ran as part of the full suite; that does not constitute a protocol review of them. No live DNS/provider tests were enabled.
