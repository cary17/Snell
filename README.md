```markdown
# Snell Server Docker Image

支持 Snell v3 到 v6+ 的 Docker 镜像，自动适配不同版本的配置格式。

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
  -e PSK=your_password \
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
      - PSK=your_password     # 密钥（不设置则随机生成）
```

## 环境变量

| 变量 | 说明 | 默认值 |
|------|------|--------|
| `LISTEN` | 监听地址/端口 | 随机端口 (10000-65535) |
| `PSK` | 预共享密钥 | 随机生成 (32-64位) |
| `IPV6` | 启用 IPv6 (仅 v3/v4/v5) | 默认 false |
| `DNS` | DNS 服务器 | 见下方说明 |
| `DNS_IP_PREFERENCE` | DNS 偏好 (v6+) | `prefer-ipv4` |
| `EGRESS_INTERFACE` | 出口网卡 (v5+) | - |
| `OBFS` | 混淆模式 (v6-) | - |
| `HOST` | 混淆域名 (v6-) | - |

> **注意**：
> - 仅 v3/v4/v5 版本需要`IPV6` 配置项，v6+ 版本IPv6 行为完全由 `dns-ip-preference` 控制

### DNS 默认值说明

| DNS_IP_PREFERENCE | IPV6 状态 | DNS 默认值 |
|-------------------|-----------|------------|
| `ipv6-only` | 自动启用 | `2001:4860:4860::8888, 2606:4700:4700::1111` |
| `ipv4-only` | 自动禁用 | `8.8.8.8, 1.1.1.1` |
| `default`/`prefer-ipv4`/`prefer-ipv6` | 自动启用 | `8.8.8.8, 1.1.1.1, 2001:4860:4860::8888, 2606:4700:4700::1111` |

## LISTEN 格式示例

| 写法 | 说明 | 实际生成配置 |
|------|------|-------------|
| `20000` | 自动生成 IPv4+IPv6 | v3/v4/v5: `:::20000`<br>v6+: `0.0.0.0:20000, [::]:20000` |
| `20000, 20001` | 多端口 (仅 v6+) | `0.0.0.0:20000, [::]:20000, 0.0.0.0:20001, [::]:20001` |
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
psk = your_password
dns = 8.8.8.8, 1.1.1.1, 2001:4860:4860::8888, 2606:4700:4700::1111
dns-ip-preference = prefer-ipv4
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

输出示例（v3/v4/v5）：
```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
[snell-server]
listen = :::20000
psk = your_password
ipv6 = false
dns = 8.8.8.8, 1.1.1.1
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

## 注意事项

- 未设置 `PSK` 时，随机密钥会显示在日志中
- 多端口监听需要 v6+，低版本只使用第一个端口
- 使用 host 网络模式时不需要端口映射，直接使用主机端口
- 如需桥接模式，请移除 `--network host` 并添加端口映射 `-p 20000:20000`
- 容器重启不会改变已生成的配置（配置文件持久化）
- v6+ 版本已移除 `ipv6` 配置项，IPv6 行为由 `dns-ip-preference` 控制
- v3/v4/v5 可通过 `IPV6=true/false` 控制是否启用 IPv6
- v3/v4/v5 使用 `:::端口` 格式同时监听 IPv4 和 IPv6
```

## 主要修改：

1. **环境变量表格**：添加 `IPV6` 行，包含说明和默认值
2. **添加注意说明**：在环境变量下方添加 `IPV6` 配置项的详细说明
3. **注意事项**：补充 v3/v4/v5 通过 `IPV6` 控制 IPv6 的说明
