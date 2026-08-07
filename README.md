
# Snell Server Docker Image

支持 Snell 的 Docker 镜像，自动适配不同版本的配置格式。

## 支持平台

`linux/amd64` | `linux/386` | `linux/arm64` | `linux/arm/v7`

## 快速开始

### 基础运行（自动生成随机 PSK 和端口）

```bash
docker run -d \
  --name snell \
  --restart always \
  --network host \
  -e LISTEN=20000 \
  ghcr.io/cary17/snell:latest
```

### 指定端口和密码

```bash
docker run -d \
  --name snell \
  --restart always \
  --network host \
  -e LISTEN=20000 \
  -e PSK=your_password_16 \
  ghcr.io/cary17/snell:latest
```

## Docker Compose

```yaml
services:
  snell:
    image: ghcr.io/cary17/snell:latest
    container_name: snell
    restart: always
    network_mode: host
    environment:
      - LISTEN=20000          # 监听端口
      - PSK=your_password_16  # 密钥（不设置则随机生成）
```

## 本地构建

默认构建会优先从 Snell 官方下载二进制包，失败后再尝试仓库 `Version/` 备份。若要直接使用当前仓库 `Version/` 目录中的二进制包构建，可增加 `USE_LOCAL_BINARY=true`：

```bash
docker build \
  --build-arg SNELL_VERSION=v5.0.1 \
  --build-arg USE_LOCAL_BINARY=true \
  -t snell:v5.0.1 .
```

本地包路径需匹配 `Version/vX.Y.Z/snell-server-vX.Y.Z-linux-ARCH.zip`。仓库内归档必须在 `Version/SHA256SUMS` 中有对应条目并通过校验；全新官方版本若尚无预登记摘要，构建会通过 HTTPS 下载并把实际 SHA-256 写入镜像的 `/snell-archive-sha256`，但这只是来源记录，不等同于上游签名验证。

## 环境变量

| 变量 | 说明 | 默认值 |
|------|------|--------|
| `LISTEN` | 监听地址/端口 | 随机端口 (10000-65535) |
| `PSK` | 预共享密钥 | 随机生成，必须为 16-180 字节；仅允许字母、数字和 `. _ + = / -` |
| `IPV6` | IPv6 配置（v3-v5 直接控制；v6+ 由 `DNS_IP_PREFERENCE` 统一决定） | v3-v5 默认 false |
| `DNS` | DNS 服务器 | 见下方说明 |
| `DNS_IP_PREFERENCE` | DNS/IP 偏好 (v6+) | `default` |
| `EGRESS_INTERFACE` | 出口网卡 (v5+) | - |
| `OBFS` | 混淆模式（仅 v3-v5；v6+ 使用 MODE） | - |
| `HOST` | 混淆域名（仅 v3-v5） | - |
| `LOGLEVEL` | 运行时日志等级，由入口脚本转换为 `snell-server -l` | 不设置 |

> **注意**：
> - v3-v5 直接使用 `IPV6`。
> - v6+ 使用 `prefer-ipv4`/`ipv4-only` 时统一生成 `ipv6 = false`，使用 `prefer-ipv6`/`ipv6-only` 时统一生成 `ipv6 = true`。
> - 如果 v6+ 的 `IPV6` 与 `DNS_IP_PREFERENCE` 冲突，`Snell.sh` 会在写入 `.env`/Compose 前提示两种处理方式：`1` 重新提交不冲突的两个值，或 `2` 由本项目按 `DNS_IP_PREFERENCE` 自动处理。
> - 整个冲突处理流程共用 30 秒总时限；超时或 EOF 默认采用方式 `2`。无效选择会在剩余时间内继续提示。选择 `1` 后，新值必须无冲突才会覆盖旧值。
> - 通过 `Snell.sh` 安装或重配时，最终值会持久写入 `/opt/snell/.env`。直接运行容器时，入口脚本不处理冲突，只输出警告并原样生成两个有效值；未定义环境变量会被丢弃，已定义配置项的非法值会警告并回退默认值或省略该可选项。
> - 如需强制保留指定的 `IPV6` 值，请将 `DNS_IP_PREFERENCE` 设为 `default` 或取消设置。

### DNS 默认值说明

未显式设置 `DNS` 时，容器首次生成配置会进行简单网络探测：

| 网络探测结果 | DNS 默认值 |
|--------------|------------|
| 国内网络 | `119.29.29.29, 223.5.5.5`，如 IPv6 可用则追加 `2402:4e00::, 2400:3200::1` |
| 国际网络或无法判断 | `8.8.8.8, 1.1.1.1`，如 IPv6 可用则追加 `2001:4860:4860::8888, 2606:4700:4700::1111` |

`DNS_IP_PREFERENCE` 支持 `default`、`prefer-ipv4`、`prefer-ipv6`、`ipv4-only` 和 `ipv6-only`。v6+ 的明确偏好值会自动决定 `ipv6`；偏好为 `default` 或未设置时，才保留显式 `IPV6`，两者都未设置时不写入相关配置项。

### 日志等级

`LOGLEVEL` 是可选覆盖项；未设置时不传递 `-l`，Snell 使用自身默认等级，服务仍可正常启动。

实测 v3.0.1 至 v6.0.0rc 均支持以下区分大小写的等级：

`trace`、`verbose`、`info`、`notify`、`warning`、`error`

Docker 示例：

```yaml
environment:
  - LOGLEVEL=info
```

设置 `LOGLEVEL` 时只作为启动参数传给 `snell-server -l`，不是 Snell 的 `snell.conf` 配置项。不要写入 `log = ...`。

## LISTEN 格式示例

| 写法 | 说明 | 实际生成配置 |
|------|------|-------------|
| `20000` | 自动生成 IPv4+IPv6 | v3/v4/v5: `:::20000`<br>v6+: `0.0.0.0:20000, [::]:20000` |
| `20000, 20001` | 多端口 (仅 v6+) | v3/v4/v5: `:::20000`<br>v6+: `0.0.0.0:20000, [::]:20000, 0.0.0.0:20001, [::]:20001` |
| `0.0.0.0:20000` | 仅 IPv4 | `0.0.0.0:20000` |
| `[::]:20000` | 仅 IPv6 | `[::]:20000` |
| `:::20000` | 双栈简写 | `:::20000` |

## 版本差异

| 版本 | LISTEN 生成格式 | 多端口 | ipv6 配置项 | OBFS/HOST | DNS_IP_PREFERENCE |
|------|----------------|--------|-------------|-----------|-------------------|
| v3 | `:::端口` | ❌ | ✅ | ✅ | ❌ |
| v4-v5 | `:::端口` | ❌ | ✅ | ✅ | ❌ |
| v6+ | `0.0.0.0:端口, [::]:端口` | ✅ | ✅ (由 DNS_IP_PREFERENCE 统一决定) | ❌ | ✅ |

> **说明**：v3/v4/v5 均使用 `:::端口` 格式实现双栈监听；v6+ 使用 `0.0.0.0:端口, [::]:端口` 格式，更清晰且支持多端口。

### Alpine / musl 系统

官方 Snell 原生二进制不支持当前 Alpine/musl 运行环境。安装脚本选择“原生二进制”时会提示是否改用 Docker：

- 选择“是”：沿用已填写的版本和配置，继续选择 Docker 网络模式及镜像仓库后安装。
- 选择“否”：取消安装，不下载二进制、不写入原生配置、不创建服务。

不建议通过第三方源在 Alpine 上额外安装 glibc 来强行运行官方二进制；请使用 Docker，或改用 Debian、Ubuntu、Rocky Linux 等 glibc 发行版。

## 安装脚本

普通用户直接运行进入 TUI：

```bash
bash Snell.sh
```

AI agent 不需要读取完整脚本，先读取仓库根目录的 [`AGENT.md`](AGENT.md)，或执行：

```bash
bash Snell.sh --agent-help
```

Agent 可以省略配置文件，直接通过参数或标准输入提供配置；安装前建议先使用 `--dry-run`。安装脚本支持源码二进制和 Docker Compose 两种方式，并会按所选方式自动检查并安装所需依赖。

- 原生安装：Snell 配置写入 `/etc/snell/snell.conf`；日志等级单独保存并写入 systemd/OpenRC 的启动参数，修改后重启服务。
- Docker 安装：配置写入 `/opt/snell/.env` 和 `/opt/snell/docker-compose.yml`；普通重启不创建新容器，修改配置或版本时先删除旧容器再重建。镜像以非 root `snell` 用户运行，只接受文档列出的配置环境变量。
- 如果用户将配置文件挂载到 `/snell/snell.conf`，挂载文件优先级最高：入口脚本不读取环境变量生成或修正配置，不修改文件，直接原样启动。支持只读挂载。
- PSK 必须为 16-180 字节，并且仅允许字母、数字和 `. _ + = / -`。

```text
支持的服务管理器：systemd、OpenRC
支持的包管理器：apt、dnf、yum、pacman、zypper、apk
```

## 镜像仓库

```bash
# GHCR
docker pull ghcr.io/cary17/snell:latest
docker pull ghcr.io/cary17/snell:v6    # 大版本标签

# Docker Hub
docker pull cary17/snell:latest
docker pull cary17/snell:v6
```

## 查看配置

```bash
docker logs snell
```

输出示例（v6+）：
```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
[snell-server]
listen = 0.0.0.0:20000, [::]:20000
psk = your_password_16
dns = 8.8.8.8, 1.1.1.1, 2001:4860:4860::8888, 2606:4700:4700::1111
dns-ip-preference = prefer-ipv4
ipv6 = false
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

输出示例（v3/v4/v5）：
```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
[snell-server]
listen = :::20000
psk = your_password_16
ipv6 = false
dns = 8.8.8.8, 1.1.1.1
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

## 注意事项

- 未设置 `PSK` 时，随机密钥会显示在日志中，方便通过 `docker logs snell` 查看
- 多端口监听需要 v6+，低版本只使用第一个端口
- 如需桥接模式，请移除 `--network host` 并添加端口映射 `-p 20000:20000`
- 容器重启不会改变 `.env` 和 Compose 中的固定配置；修改配置或版本时会删除旧容器并按新配置重建。
- v6+ 冲突时提供 30 秒交互选择：重新提交无冲突参数，或按 `DNS_IP_PREFERENCE` 自动处理；超时默认自动处理
- v3/v4/v5 可通过 `IPV6=true/false` 控制是否启用 IPv6
- 使用 `:::端口` 格式同时监听 IPv4 和 IPv6
