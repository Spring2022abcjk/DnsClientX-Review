# 独立复审方法

审查对象 EvotecIT/DnsClientX `DnsClientX-v2.1.2`，提交 `1cfb438fd4c75a8ae54d457fb3073ab4aeb3718a`。审查仓库开始时 `work`、HEAD 与 `origin/main` 均为 `81f50df3fd66ff5385b4ffdefff7e361898f4081`，工作树干净；fetch main 后从 origin/main 新建本分支。没有 cherry-pick。通过 `./bootstrap/bootstrap.sh -NoProfile -File scripts/Get-UpstreamSource.ps1` 获取 `/workspace/DnsClientX-upstream`；脚本校验 tag 和 HEAD，复查 HEAD 与目标一致且工作树干净。源码和构建副本均在审查仓库之外；没有改动原始上游工作树或 Cloud 管理脚本。

先阅读上游实现和 RFC 1035、6891、7871、7766、9267，按独立边界构造探针，观察结果后才 fetch PR #3 的 head（确认 `11a13a27b1e82229fdf69d59dd465d6dcea2757c`），阅读要求的五个文件并逐项对照。探针没有沿用第一轮测试项目；随后增加实际响应路径探针以核对第一轮描述。RFC 9267 是信息性安全分析，不应把所有建议直接当成标准强制要求。

在 Linux x64、.NET SDK 10.0.403、net8.0 运行临时 C# 探针；复制上游项目到 `/workspace/scratch/dns-independent` 后编译，使用公开 API 和仅限回环的 TCP 监听器，未构建长期测试工程。所有 PowerShell 命令均通过 bootstrap。没有运行完整上游测试套件；PR #3 的套件结果不是本轮复跑结果。未进行 Windows、其他框架、实际 DoT 握手、DoQ 或互联网解析器测试；池化路径结论来自静态调用链而非实测。没有证明任何内存破坏、远程代码执行或可利用攻击链。
