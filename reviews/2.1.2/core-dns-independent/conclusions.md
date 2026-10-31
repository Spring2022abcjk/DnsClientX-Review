# 最终意见

| 第一轮 | 本轮裁定 | 本轮严重度 | 要点 |
|---|---|---|---|
| F-01 | Confirmed with Qualification | Medium | 公开直接 TCP 实测错帧；第一轮将池化 TCP/DoT 归入影响范围是重大错误，池在发送前拒绝超长消息。 |
| F-02 | Confirmed | Low | 无效 ECS 前缀实际被编码；服务器 FORMERR 条款不应误作客户端接收义务。 |
| F-03 | Confirmed | Low | 50 标签限制使公开 EDNS helper 拒绝合法名称；完整名称解析器没有该上限。 |
| F-04 | Confirmed with Qualification | Low | 匹配响应中的 header 指针被解释为根；不等于证明安全攻击或所有指向根的压缩指针都非法。 |
| F-05 | Confirmed with Qualification | Informational | 128 跳阈值和误导性循环错误均复现；防御资源预算合理，未证明 RFC 违规或安全漏洞。 |

建议优先修正直接 TCP 的完整消息长度验证，接着校验 ECS 输入和轻量解析器的合法名称范围；对压缩目标加验证，同时为压缩深度预算提供准确诊断。长期测试项目由另一会话实现，本复审仅提供可复现构造和测试建议。

本轮完成独立静态路径分析、规范核对、公开 API 序列化与 loopback TCP 发送/响应探针，再逐项核对 PR #3；没有运行完整套件、TLS 网络实测或全面审查其他传输、DNSSEC、UPDATE、区域传送及所有 RDATA。原始上游工作树保持干净。第一轮全套测试数字不作为本轮独立验证结果。
