# 逐项裁定

以下行号均指固定上游提交；行为、协议和安全影响分别评价。严重度以实际可触达性和已证明影响为准，而非按理论最坏结果。

## F-01 — Confirmed with Qualification；Medium（直接 TCP 可用性/互操作）

- **构造及结果：** `DnsMessage.SerializeDnsWireFormat`（`DnsClientX/ProtocolDnsWire/DnsMessage.cs:101-133`）只在第 129 行检查 OPT RDLENGTH；可用公开 `EdnsOption` 子类提供 65,531 字节数据，option 总长 65,535，整个 `a A` 消息 65,565。公开 `DnsWireQueryClient.QueryTcpAsync`（`DnsWireQueryClient.cs:66-79`）到 `SendQueryOverTcp`（`DnsWireResolveTcp.cs:135-177`）在第 160 行把长度转为 ushort，再写入整个数组。回环服务器确实读到前缀 29 和 65,565 字节体，随后关闭连接；客户端报 EOF。第一轮 65,564/28 构造也可行，数值差别来自选用的名称和 option。
- **协议与义务：** RFC 1035 §4.2.2 的两字节前缀代表随后的消息长度，65,565 无法表示；发送方必须避免生成该错误帧。RFC 7766 §8 的一次写入是 SHOULD，与长度截断是不同问题。OPT RDLENGTH 合法不代表全消息可放入 TCP 帧（RFC 6891 §6.1.2）。这是错误配置下产生的不合法传输，不是合法的超长 TCP DNS 消息。
- **路径修正：** 第一轮将池化 TCP/DoT 列为受影响的结论是重大范围错误：`DnsStreamConnectionPool.cs:37-51` 的共同入口在连接及写入前拒绝 >65,535；`DnsWireResolveTcp.cs:72-89` 的复用 TCP 和 `DnsWireResolveDot.cs:77-89` 的 DoT（包括临时池）都走该入口。`DnsWireQueryClient` 的直接 TCP 实测受影响；UDP 回退经直接 TCP 的可能路径见 `DnsWireQueryClient.cs:39-57`，但本轮未实测。标准 TCP 复用关闭时亦走直接发送。DoT/池化保护仅静态确认，不能据此声称测试过 TLS。对远端的持久连接污染、安全影响未证明，本地发送方自选极大 option 是前提。
- **建议：** 在所有 stream 写入之前统一验证完整消息长度并在序列化出口考虑统一上限；保留池的检查。给 65,535 和 65,536 及直接/池化/TLS 路径分别做边界测试。

## F-02 — Confirmed；Low

- **构造及结果：** `DnsClientX/Edns/EcsOption.cs:27-53` 未校验前缀，限定复制的地址字节数后仍将前缀转为 byte。`192.0.2.1/33` 经公开 `DnsMessage`/`DnsMessageOptions.Subnet` 序列化为 option `0008 0008 0001 21 00 C0000201`；IPv6 `/129` 和 IPv4 `/-1` 也未拒绝（见 reproduction）。合法 `/25` 得 `C0000280`，低位清零。`DnsMessage.cs:136-145` 和 `DnsWireQueryBuilder.cs:6-30` 将公共配置送到编码器；本轮直接验证序列化，未实测 ECS 发包。
- **协议与义务：** `/33` 本身不是 IPv4 有效网络前缀。RFC 7871 §6.1 将 SOURCE PREFIX-LENGTH 定义为地址有效位数，ADDRESS 必须按此截断并补零；查询 scope 必须为 0。IPv4 只有 32 位、IPv6 128 位，不可能按更大值编码。文中的 FORMERR **SHOULD 是服务器接收责任**，不是给本客户端附加的服务器责任；发送符合格式的 ECS 是客户端的责任，不必虚构 RFC 明文规定构造器必须抛何种异常。第一轮 RFC 引用总体适用，但将具体范围说成 §6.1 的逐字范围条款并不精确。自行传入无效参数可能导致拒绝或错误语义，未证明安全影响。
- **建议：** 解析时严格校验地址族和 0–32/0–128、CIDR 格式及整数溢出，再编码；保留合法非字节边界掩码。资源限制不是此输入校验的替代品。

## F-03 — Confirmed；Low

- **构造及结果：** `DnsWireMessageParser.cs:37,119-153,232-264` 的 `TrySkipName` 超过 50 个非根标签返回 false。公开 `TryParseEdns` 对 50 个单字节标签返回 true，对 51 和 127 返回 false；同一报文的 `TryParseQuestion` 均为 true。本次报文没有 OPT，仍按 API 契约应成功报告 EDNS 不存在；第一轮含 OPT 的构造同样可行。51 标签 wire 长 103 字节，127 标签恰好 255 字节，包括根标签。
- **协议与范围：** RFC 1035 §§2.3.4、3.1、4.1.2 规定标签最多 63 字节、名称最多 255 字节，不规定 50 标签。该 helper 的公开 API 误拒有效输入；完整响应解析使用 `DnsWireReader`（`DnsWire.cs:114-118,202-211`），不因此直接拒绝。内部 `TryContainsEdnsOption` 同样使用 skipper（`DnsWireMessageParser.cs:187-206`），DoQ 调用在 `DnsWireResolveQuic.cs:171`，实际后果未验证。50 上限限制资源有一定目的，但直接遍历最多 127 个标签有 255 字节协议界限，因此可在保留边界的同时支持有效名称。无已证明安全影响。
- **建议：** 按展开名称 255 字节及标签合法性约束，而非 50 标签；测试 50/51/127 标签与超长名称。轻量 skipper 也需分别定义是否验证压缩目标。

## F-04 — Confirmed with Qualification；Low

- **构造及结果：** 匹配事务 ID `00EF`、`example.com A IN` 的 TCP 响应，答案 owner 为 `C000`，A RDATA 为 `192.0.2.1`；回环公开 `QueryTcpAsync` 返回一个 owner `.` 的答案。`DnsWireReader.cs:67-86` 只要求目标早于指针；偏移 0 是 ID 高字节 00，被当作根终止符。完整关联检查在 `DnsWire.cs:97-131`，答案处理在 `:134,202-221`。测试有匹配 ID 和问题，不意味着任意第三方可绕过关联或网络对端检查。
- **协议与义务：** RFC 1035 §4.1.4 的 offset 以 ID 第一字节为零点的定义并不使 header 成为合法目标；同节要求指向同名的先前出现，header 的零字节不是名称出现。错误报文确实不符合压缩格式，接收端应避免将其解释为合法答案。RFC 9267 §2 提供目标验证和循环防护安全建议，不能把其对非零标签目标的建议泛化为本轮已证明所有指向先前根标签的指针都不合法。代码未跟踪实际名称边界，单纯 `offset >= 12` 不足以证明目标合法。恶意/错误的已联系对端可提供错误 owner；缓存污染、攻击链或内存安全影响未证明。
- **建议：** 在可行情况下验证目标属于此前实际编码名称的合法标签边界，并与对未知 RDATA 的兼容性权衡；至少拒绝 header、越界、前向及循环目标，并保留长度/资源限制。添加同样偏移处为零和非零、合法先前标签及根标签的测试。

## F-05 — Confirmed with Qualification；Informational（诊断/互操作权衡）

- **构造及结果：** `DnsWireReader.cs:60-83` 栈上分配 128 个目标，达到容量抛 `DNS compression pointer loop detected`。回环 TCP 响应中 128 个 A 答案的 owner 各指向前一 owner（首个指向 question 的 `example.com`），128 跳成功；129 跳报上述异常。每个目标不同且严格后退，展开名称 13 字节，报文 2,093 字节；没有循环。此前独立的多 Question 公共 parser 探针也得到同一边界。该长度由 29 字节头及问题加 129 个 16 字节记录计算。
- **规范与裁定：** RFC 1035 §4.1.4 允许指针代表名字，要求理解接收的压缩；没有规定 128 跳限额。这里有合法的有限嵌套指针和互操作损失，但仅凭 RFC 没有规定数字，不能证明合理的资源上限违反 RFC。RFC 9267 §2 明确讨论嵌套指针的风险、限制和替代措施；其信息性建议不能直接推导 128 是协议规定。检测真实循环仍有意义：即使每个指针目标比指针位置小，标签读取可向前走回同一指针。现有上限控制时间（逐项扫描 visited 的最坏成本受限）和栈空间；`loop detected` 对超限无环输入不准确。没有证明安全漏洞。第一轮 Low 作为互操作/诊断问题可理解，但本轮降为 Informational；不认定协议违规。
- **建议：** 保留明确的资源预算并以专门的深度/资源上限错误报告；独立检查实际循环。记录策略及兼容性取舍，测试 128/129、真实循环与展开长度界限。
