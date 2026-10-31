# 规范依据与争议

- [RFC 1035 §§2.3.4、3.1、4.1.2](https://www.rfc-editor.org/rfc/rfc1035#section-2.3.4)：标签至多 63 octets，完整 wire 名称至多 255 octets，包括长度字节与根终止符。127 个一字节标签加根恰为 255；51 个仅 103。不应将 50 当成协议上限。名称的展示字符串长度不能替代 wire 长度。
- [RFC 1035 §4.1.4](https://www.rfc-editor.org/rfc/rfc1035#section-4.1.4)：压缩是对同名先前出现的引用；offset 的起点是消息第一个 ID 字节，这说明坐标系而非授权把 header 当作名称。指针可以指向此前压缩名称；规范未规定 128 跳最大值。接收端需要有界处理；针对有限嵌套的兼容性和资源预算是权衡，不能只从未列明上限得出强制无限解析。严格验证先前标签边界可能受未知 RDATA 影响。
- [RFC 9267 §2](https://www.rfc-editor.org/rfc/rfc9267#section-2)：信息性文档列举指针、循环和嵌套处理风险及防护；其建议首次指针指向先前非零标签且对嵌套持谨慎态度。它不是将所有实现选择转为 RFC 1035 强制义务的授权，也不能仅凭建议排除此前根终止符的所有合法性争议。单纯每跳指向比该指针更早的地址并不自动排除从标签向前读取再回到指针的循环，仍应检测重复或采用其他严格的界限。
- [RFC 1035 §4.2.2](https://www.rfc-editor.org/rfc/rfc1035#section-4.2.2) 的 TCP 二字节长度描述随后 DNS 消息；最多能表示 65,535。超长消息不能正确置入一个帧。[RFC 7766 §8](https://www.rfc-editor.org/rfc/rfc7766#section-8) 对前缀与消息一次交给 TCP 的 SHOULD 是独立的性能/互操作建议，本轮未将两次写入归入 F-01。
- [RFC 6891 §6.1.2](https://www.rfc-editor.org/rfc/rfc6891#section-6.1.2) 规定 OPT 格式及附加区，RDLENGTH 是 16 位；它不保证整个 DNS 消息符合 TCP 帧长度。对 OPT owner 压缩根的细节未作最终判断。
- [RFC 7871 §6.1](https://www.rfc-editor.org/rfc/rfc7871#section-6.1) 的 family 1/2 分别为 IPv4/IPv6，地址按 source prefix 截断并补零，查询 scope MUST 为零。一个地址只有 32/128 位，因此大于该位数的输入不能生成符合语义的地址字段。§6.1 对收到地址字节数量错误等情况的 FORMERR 是服务器 SHOULD；§7.1 的来源选取与客户端构造有关，不能把服务器义务套给此客户端。本文区分无效调用参数、实际发出的畸形 option 和未验证的远端处理。
