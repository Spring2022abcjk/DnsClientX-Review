# Findings

Target: upstream commit `1cfb438fd4c75a8ae54d457fb3073ab4aeb3718a` (`DnsClientX-v2.1.2`). Product source was not changed.

Severity scale used here: **Medium** is a reproducible interoperability failure on a supported public query path for a caller-configurable edge input; **Low** is a narrower malformed-input or valid-message handling defect without demonstrated memory-safety impact. None of these findings demonstrates code execution or a memory-safety failure.

## F-01 — TCP frame length wraps for serialized messages over 65,535 octets

- **Severity:** Medium
- **Files/functions:** `DnsClientX/ProtocolDnsWire/DnsMessage.cs`, `DnsMessage.SerializeDnsWireFormat`, lines 122–133; `DnsClientX/ProtocolDnsWire/DnsWireResolveTcp.cs`, `SendQueryOverTcp`, lines 159–163; `DnsClientX/ProtocolDnsWire/DnsStreamConnectionPool.cs`, `WriteQueryAsync`, lines 357–365. Public direct path: `DnsWireQueryClient.QueryTcpAsync`, lines 66–79.
- **Protocol requirement:** RFC 1035 §4.2.2 frames a TCP DNS message with a two-octet length. The body must fit that unsigned 16-bit value (maximum 65,535 octets).
- **Trigger:** A caller supplies a large EDNS option such that the OPT RDLENGTH still fits 16 bits but the complete DNS message exceeds 65,535 octets. `DnsMessage.SerializeDnsWireFormat` checks only the OPT RDLENGTH at line 129, then returns the full array. The two TCP framers write the low 16 bits of `query.Length` without checking the total.
- **Observed:** A local probe constructed `NsidOption(new byte[65520])`. Serialization returned 65,564 octets. The TCP prefix was `00 1C` (28), not 65,564; the local server observed 65,536 bytes after the declared body as unframed data. The call proceeded and the probe server returned a response.
- **Expected:** Reject a serialized DNS body longer than `ushort.MaxValue` before transmission (or otherwise ensure the writer cannot emit a frame whose prefix disagrees with the body).
- **Impact:** Large caller-configured EDNS options sent over TCP or pooled TCP/DoT can be misframed; a peer can read only a 28-octet message and interpret remaining bytes as another frame or garbage. Ordinary small queries are unaffected.
- **Evidence:** Reproduced through the public `DnsWireQueryClient.QueryTcpAsync` path against an ephemeral loopback TCP server. Probe output: `OversizeQuery total=65564 tcpLengthPrefix=28`; `TcpServerObserved advertisedBody=28 queryTotal=65564 extraUnframedBytes=65536`.

## F-02 — ECS encoder emits out-of-range source prefix lengths

- **Severity:** Low
- **Files/functions:** `DnsClientX/Edns/EcsOption.cs`, `EcsOption.GetData`, lines 27–53; called while building OPT RDATA by `DnsClientX/ProtocolDnsWire/DnsMessage.cs`, lines 136–145.
- **Protocol requirement:** RFC 7871 §6.1 limits the Source Prefix-Length to 0–32 for IPv4 and 0–128 for IPv6; the address portion must contain the corresponding number of significant octets. Query Scope Prefix-Length is zero.
- **Trigger:** A caller configures ECS `192.0.2.0/33` (or an IPv6 prefix above 128). `GetData` caps the number of copied bytes to the address size but writes the unchecked prefix into the option.
- **Observed:** `DnsMessage` serialized the IPv4 `/33` ECS value without throwing. Its option data was `00 01 21 00 C0 00 02 00`: family 1, source prefix 33, scope 0, four address octets.
- **Expected:** Reject the CIDR prefix before encoding because it is outside the selected address family's range.
- **Impact:** Only invalid caller-supplied ECS configurations are affected. A resolver may reject or ignore the option, so the query can lose its intended ECS behavior or be rejected.
- **Evidence:** Reproduced by serializing a public `DnsMessage` with `DnsMessageOptions(EnableEdns: true, Subnet: new EdnsClientSubnetOption("192.0.2.0/33"))`.

## F-03 — Lightweight EDNS parser rejects valid DNS names with more than 50 labels

- **Severity:** Low
- **Files/functions:** `DnsClientX/ProtocolDnsWire/DnsWireMessageParser.cs`, `MaxNameSegmentsToSkip` line 37 and `TrySkipName` lines 232–264; public `TryParseEdns` calls it for Questions and RR owners at lines 139–179.
- **Protocol requirement:** RFC 1035 §§2.3.4 and 4.1.2 limit a wire name to 255 octets and each label to 63 octets; they do not impose a 50-label limit. A name of 51 one-octet labels is 103 octets including the root and is valid.
- **Trigger:** Call `DnsWireMessageParser.TryParseEdns` with a valid EDNS message whose Question name has 51 one-octet labels.
- **Observed:** A `DnsMessage` containing 51 `a` labels and an OPT record serialized to a 130-octet message, but `TryParseEdns` returned `false`.
- **Expected:** The helper should parse the valid name within the DNS 255-octet maximum and report the OPT payload size.
- **Impact:** Callers of this public lightweight parser cannot inspect EDNS data for valid names above the helper's undocumented cap. The full `DnsWireReader` parser does not use this 50-label limit.
- **Evidence:** Reproduced with a deterministic in-memory wire message: `TryParseEdns51Labels=False wireLength=130`.

## F-04 — Full parser accepts a compression pointer into the DNS header

- **Severity:** Low
- **Files/functions:** `DnsClientX/ProtocolDnsWire/DnsWireReader.cs`, `ReadName`, lines 74–86; consumed by `DnsWire.ParseMessage` for Questions and RR names (`DnsClientX/ProtocolDnsWire/DnsWire.cs:114–141,202–221`).
- **Protocol requirement:** RFC 1035 §4.1.4 defines a compression pointer as an offset to a prior occurrence of a domain name. A transaction-ID/header byte is not a prior name occurrence.
- **Trigger:** A response with transaction ID `0x00EF`, one matching `example.com A IN` Question, and one otherwise well-formed A answer uses owner pointer `C0 00` (offset zero). The first transaction-ID octet is zero, so the decoder interprets it as the root label.
- **Observed:** The full response parser accepted the response and exposed the answer owner as `.`. The transaction ID and Question still matched the query.
- **Expected:** Reject a compression target that is not a previously encoded domain-name label boundary/name occurrence.
- **Impact:** A malformed response from the configured peer can be returned with a fabricated owner name. The parser remains bounded, and the tested path does not bypass the separate transaction-ID, Question, or connected-UDP-peer checks. No memory-safety effect was observed.
- **Evidence:** Reproduced by invoking the shared full response parser on a locally constructed packet: `HeaderTargetPointer accepted=true owner=.`

## F-05 — A backward-only 129-hop compression chain is rejected as a loop

- **Severity:** Low
- **Files/functions:** `DnsClientX/ProtocolDnsWire/DnsWireReader.cs`, `ReadName`, lines 60–83.
- **Protocol requirement:** RFC 1035 §4.1.4 defines backward offsets and the expanded-name limit; it specifies no 128-pointer-chain limit. Each pointer in the reproducer points to an earlier occurrence of the same expanded `example.com` owner name.
- **Trigger:** Parse a valid response with one Question and 129 distinct A records for `example.com`; each RR owner pointer targets the previous RR owner's compressed name, producing a finite backward chain. The complete message is 2,093 octets and each expanded name is 13 octets.
- **Observed:** A 128-hop chain parsed. The 129-hop packet failed with `DNS compression pointer loop detected`, although all offsets strictly decreased and no pointer target repeated.
- **Expected:** Decode the chain to the same name, or report a distinct documented resource-limit condition if the implementation intentionally imposes a cap. The current “loop detected” result does not describe the input.
- **Impact:** A valid but unusually compressed response containing a long chain is rejected. Typical encoders point directly to an earlier full occurrence, so ordinary responses are unaffected.
- **Evidence:** Deterministic packet comparison: `CompressionChain128 accepted answers=128`; `CompressionChain129 rejected DnsClientException: DNS compression pointer loop detected.`
