
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

本地包路径需匹配 `Version/vX.Y.Z/snell-server-vX.Y.Z-linux-ARCH.zip`。

## 环境变量

| 变量 | 说明 | 默认值 |
|------|------|--------|
| `LISTEN` | 监听地址/端口 | 随机端口 (10000-65535) |
| `PSK` | 预共享密钥 | 随机生成，必须为 16-180 字节；仅允许字母、数字和 `. _ + = / -` |
| `IPV6` | 启用 IPv6 ( v3/v4/v5) | 默认 false |
| `DNS` | DNS 服务器 | 见下方说明 |
| `DNS_IP_PREFERENCE` | DNS 偏好 (v6+) | `prefer-ipv4` |
| `EGRESS_INTERFACE` | 出口网卡 (v5+) | - |
| `OBFS` | 混淆模式 (v6-) | - |
| `HOST` | 混淆域名 (v6-) | - |

> **注意**：
> - 仅 v3/v4/v5 版本需要`IPV6` 配置项，v6+ 版本IPv6 行为由 `dns-ip-preference` 控制

### DNS 默认值说明

未显式设置 `DNS` 时，容器首次生成配置会进行简单网络探测：

| 网络探测结果 | DNS 默认值 |
|--------------|------------|
| 国内网络 | `119.29.29.29, 223.5.5.5`，如 IPv6 可用则追加 `2402:4e00::, 2400:3200::1` |
| 国际网络或无法判断 | `8.8.8.8, 1.1.1.1`，如 IPv6 可用则追加 `2001:4860:4860::8888, 2606:4700:4700::1111` |

未显式设置 `DNS_IP_PREFERENCE` 时，v6+ 会根据 IPv4/IPv6 连通性自动选择 `prefer-ipv4` 或 `prefer-ipv6`。

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
| v6+ | `0.0.0.0:端口, [::]:端口` | ✅ | ❌ (由 DNS_IP_PREFERENCE 控制) | ❌ | ✅ |

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

- 原生安装：配置写入 `/etc/snell/snell.conf`，修改配置后重启服务。
- Docker 安装：配置写入 `/opt/snell/.env` 和 `/opt/snell/docker-compose.yml`；普通重启不创建新容器，修改配置或版本时先删除旧容器再重建。
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
- v6+ 版本IPv6 行为由 `dns-ip-preference` 控制
- v3/v4/v5 可通过 `IPV6=true/false` 控制是否启用 IPv6
- 使用 `:::端口` 格式同时监听 IPv4 和 IPv6
