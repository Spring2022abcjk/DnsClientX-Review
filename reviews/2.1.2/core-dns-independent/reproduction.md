# 独立复现记录

运行环境 Linux x64，SDK 10.0.403，目标 net8.0；以固定提交的项目复制到 `/workspace/scratch/dns-independent/DnsClientX` 构建。临时探针位于同级 `probe`、`probe2`，未提交到报告仓库；执行：

```sh
DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_ROOT=/workspace/.review-tools/dotnet PATH=/workspace/.review-tools/dotnet:$PATH NUGET_PACKAGES=/workspace/.review-tools/nuget/packages dotnet run --project /workspace/scratch/dns-independent/probe/probe.csproj -p:TargetFrameworks=net8.0
DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_ROOT=/workspace/.review-tools/dotnet PATH=/workspace/.review-tools/dotnet:$PATH NUGET_PACKAGES=/workspace/.review-tools/nuget/packages dotnet run --project /workspace/scratch/dns-independent/probe2/probe.csproj -p:TargetFrameworks=net8.0
```

复制品为构建隔离，原始上游 HEAD 和工作树在运行后再次核实。以下给出不依赖临时文件路径的构造方法：

1. 自定义 `EdnsOption(65000)`，`GetData()` 返回 `new byte[65531]`；构造名称 `a`、A 类型、`DnsMessageOptions(UdpBufferSize:4096, Options: new[]{option})`。序列化为 65,565 字节。回环 `TcpListener` 接收公开 `DnsWireQueryClient.QueryTcpAsync`，持续读取完整字节：收到总共 65,567 字节，包括大端前缀 `001D`（29）和 65,565 字节体；不是预期的发送前拒绝。服务器关闭后客户端抛 `EndOfStreamException`，没有声称收到成功 DNS 响应。TCP 流接收量为实际观察，不代表每个远端均会同样处理尾部。
2. 序列化 `new DnsMessage("a", A, new DnsMessageOptions(UdpBufferSize:4096, Subnet:new EdnsClientSubnetOption(s)))`。`192.0.2.129/25` 的 option 为 `0008000800011900C0000280`；`192.0.2.1/33` 为 `0008000800012100C0000201`，无异常；`2001:db8::1/129` 和 `192.0.2.1/-1` 也无异常（探针只输出末 12 字节，前者不足以单独重建全部 option；结论仅为未拒绝）。预期无效前缀在编码前拒绝。
3. 12 字节全零 header，将 QDCOUNT 设为 1，接着重复 n 次 `01 61`，再接 `00 0001 0001`。n=50/51/127 时 wire 名称长度分别为 101/103/255；`TryParseQuestion` 均 true，`TryParseEdns` 分别 true/false/false。无 OPT 时成功解析应返回 true 并报告不支持 EDNS。
4. 回环 TCP 服务读取 `example.com A IN` 查询（ID 固定 `00EF`），返回 QR=1、QDCOUNT=1、ANCOUNT=1，复制 question，answer 为 `C000 0001 0001 00000001 0004 C0000201`。公开查询成功，`Answers[0].Name` 为 `.`；预期拒绝非法 header 目标。另将 QNAME 构造为 `C000` 的公共 `TryParseQuestion` 也返回 true、`.`。
5. 同样的 query/response，将 ANCOUNT 设置为 n，答案首 owner 指向 question 的偏移 12，后续 owner 每次指向上一条 owner 的起始偏移；各自尾部为 `0001 0001 00000001 0004 C0000201`。n=128 成功返回 128 answers，n=129 抛 `DnsClientException: DNS compression pointer loop detected.`；所有指针位置和目标各不相同且目标在前，名称展开为 `example.com.`。预期要么解析，要么以明确资源上限诊断；不应描述为已证实循环。

以上测试为点状探针而非完整测试套件、模糊测试或性能测试。没有分别实测 pooled TCP、DoT、DoQ、UDP 回退、IPv6 网络传输或恶意远端的后续影响；不能把未测解释成不存在。第一轮报告中的其他测试和全套测试为其自身证据，本轮未独立复跑。
