# Alpine + glibc 验证记录

## 迁移实施状态

用户后续明确：不再本地构建或测试，运行验收交给 GitHub；v3 TLS、v5 QUIC、v6 端到端转发及稳定性/性能暂缓测试，功能继续保留。

Subagent 完成了 Dockerfile、发布校验和测试脚本的部分修改，随后因调用额度耗尽中断；主代理接手收尾并作静态审查。正式 Dockerfile 现已切换为 `alpine:latest` + Debian bookworm 同源运行库，保留原版 Snell 二进制及入口逻辑。
安装器桥接模式补齐 TCP/UDP 两种映射，避免部署配置阻断 QUIC；原生安装的 Alpine 回退策略未改变。

发布工作流按本次 Buildx 输出的 digest 验证实际注册表产物；每个可用架构执行启动/配置验收，amd64 v3-v5 再验证普通/HTTP 混淆及支持的转发路径。验证通过后才更新 rolling 标签和成功记录；完整版本标签仍在验证前推送。
手动工作流使用正式 Dockerfile，覆盖四版本与四架构的 15 个有效组合（排除 v6 rc2 arm/v7），不推送制品。

本轮代码改动未做任何本地构建或测试，也未提交、推送或触发 GitHub。以下结果是**迁移前实验记录**，不等于本轮正式产物已通过验收。

## 迁移前结论

linux/amd64 上，官方 Alpine 加同源 glibc/C++ 运行库可启动 v3.0.1、v4.1.1、v5.0.1、v6.0.0rc2。
59 个启动/配置场景全部通过。真实客户端转发 8 组中 7 组通过；v3 TLS 混淆与当前 Mihomo 的互通失败，Debian 对照也失败。
这不是所有协议功能的完整验收，也不是长期稳定性或性能测试。当时正式 Dockerfile、入口脚本和发布工作流尚未修改。

## 运行环境

- Alpine：3.24.2，来自本次拉取的 `alpine:latest`。
- 运行库来源：`debian:bookworm-slim`，三个包均来自同一发行版、同一架构。
- libc6：`2.36-9+deb12u14`。
- libstdc++6 / libgcc-s1：`12.2.0-14+deb12u1`。
- 客户端：Mihomo `v1.19.31 linux amd64`，镜像 `metacubex/mihomo:latest`。
- Snell 进程为非 root；从 `/proc/PID/maps` 确认实际加载了 Debian 的 libc、libstdc++、libgcc_s 和 glibc 加载器。
- 转发测试完全在独立网络命名空间内进行，不需要外网目标，不占用宿主机 DNS 端口。
- v3 使用仓库记录的末版 v3.0.1；官方当前页面列出 v4.1.1、v5.0.1 和 v6 RC2。v6.0.0rc2 不是正式版。

本次基础制品标识：

```text
alpine:latest
sha256:294b683cb724975bec92580e1e685676bd4b50bda910ddb8c51d4cabeaec77e6
debian:bookworm-slim
sha256:3783cc01769c7b2b1b83a5c5ad96c815348e28ed7da68e2e3687004faa906251
metacubex/mihomo:latest
sha256:739edd73a352d6beb82fad6790ef9d417a4d6f061584cc3cab1bd4536d1c60e5
```

## 启动和配置

| 服务端 | 通过场景数 | 实际转发 |
| --- | ---: | --- |
| v3.0.1 | 13 | 普通、HTTP 混淆通过；TLS 混淆失败 |
| v4.1.1 | 12 | 普通、HTTP 混淆通过 |
| v5.0.1 | 13 | 普通、HTTP 混淆、出口绑定通过 |
| v6.0.0rc2 | 21 | 未做兼容客户端端到端验证 |

共同覆盖：`--version` 退出成功、非 root、IPv4/IPv6 TCP 监听、重启后配置不变、SIGTERM 正常停止、六种 LOGLEVEL、IPV6=true、随机 PSK、非法环境变量回退和只读配置挂载优先。

版本专属覆盖：v3 HTTP/TLS 配置启动，v4/v5 HTTP 配置启动，v5/v6 egress-interface 配置启动，v6 双端口的 IPv4/IPv6 监听、三种 MODE 和五种 DNS_IP_PREFERENCE。
这些选项的“启动通过”不等于它们对应的所有流量路径已验证。随机端口和自动网络探测没有在本次容器矩阵中单独覆盖。

## 实际转发及对照

使用同一份 Snell 二进制和相同版本的 glibc/C++ 库，分别运行在 Alpine 实验镜像和 Debian 对照镜像。

| 用例 | Alpine | Debian 对照 |
| --- | --- | --- |
| v3 普通模式：TCP、IPv6、UDP | 通过 | 通过 |
| v3 HTTP 混淆：TCP、IPv6、UDP | 通过 | 通过 |
| v3 TLS 混淆：TCP 大响应 | 失败 | 失败 |
| v4 普通模式：TCP、IPv6、UDP、自定义 DNS | 通过 | 通过 |
| v4 HTTP 混淆：TCP、IPv6、UDP、自定义 DNS | 通过 | 通过 |
| v5 普通模式：TCP、IPv6、UDP、自定义 DNS | 通过 | 通过 |
| v5 HTTP 混淆：TCP、IPv6、UDP、自定义 DNS | 通过 | 通过 |
| v5 egress-interface=lo：TCP、IPv6、UDP、自定义 DNS | 通过 | 通过 |

每组通过的用例包含 5 次 1 MiB IPv4 HTTP 下载并比较 SHA-256、一次 IPv6 下载、一次 SOCKS5 UDP 回声。
v4/v5 还验证代理端查询自定义 DNS，并用解析出的地址成功下载同一响应；客户端开启连接复用选项。
v5 使用 Mihomo 的 v4 兼容协议路径，不覆盖 QUIC 专用模式或 Dynamic Record Sizing 的性能收益。

v3 TLS 失败表现为响应缺失或截断，Alpine 一次收到 49,031 字节而不是 1,048,576 字节；Debian 也复现。
目前仅能排除“Alpine 独有”的简单解释，没有定位到客户端或服务端的具体根因。应再用 Surge 验收，不应宣称 TLS 混淆已通过。
当时测试脚本保留这项失败并返回非零退出码；用户随后明确将 v3 TLS 从默认验收范围移除，服务端 TLS 功能未删除。

仍待验证：v6 协议端到端、v5 QUIC、实际网卡/路由环境下的出口策略、错误 PSK 行为、长时间运行、并发压力、吞吐性能。

## 架构

官方 Alpine latest 和 Debian bookworm-slim 的镜像清单都覆盖 amd64、386、arm64 和 arm/v7。
v3/v4/v5 仓库归档覆盖四种架构；v6.0.0rc2 官方 amd64、i386、aarch64 URL 返回 HTTP 200，armv7l 返回 HTTP 404。

因此本方案可以保留 linux/386；linux/arm/v7 可保留到有上游二进制的 v3/v4/v5，不能承诺 v6。
本报告验收结论只针对 amd64。按用户后续要求，其余架构不追加本地验证，交给手动 GitHub Actions 矩阵。
收敛范围前启动的其他架构任务已经结束，临时 QEMU 注册已清理。

## 当前验收入口

`.github/workflows/test-alpine-glibc.yml` 为手动测试工作流，`.github/workflows/build.yml` 验证实际发布制品。
`tests/test_alpine_glibc.sh` 和 `tests/test_alpine_forwarding.py` 已改为接受正式单版本镜像的 `SNELL_TEST_IMAGE`，可用 `SNELL_TEST_VERSION` 对照版本；不再依赖历史实验镜像的 `/samples`。
`tests/Dockerfile.alpine-glibc` 仅作历史实验参考，不参与正式验收；不能把它的测试结果当作正式产物结果。

历史本地证据：`/tmp/snell-alpine-check-amd64-final/`、`/tmp/snell-alpine-forwarding-isolated/`、`/tmp/snell-debian-forwarding-isolated/`。
迁移前曾执行 `bash tests/test_snell.sh`、ShellCheck、Shell/Python 语法检查和 YAML 解析；正式迁移修改后未重跑，等待 GitHub Actions。
