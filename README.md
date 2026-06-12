```markdown
# Snell Server Docker Image

支持 Snell v3 到 v6+ 的 Docker 镜像，自动适配不同版本的配置格式。

## 支持平台

`linux/amd64` | `linux/386` | `linux/arm64` | `linux/arm/v7`

## 快速开始
```

```bash
# 基础运行（自动生成随机 PSK 和端口）
docker run -d --name snell --restart always ghcr.io/cary17/snell:latest

# 指定端口和密码
docker run -d \
  --name snell \
  --restart always \
  -p 20000:20000 \
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
    ports:
      - "20000:20000"
    environment:
      - LISTEN=20000          # 监听端口
      - PSK=your_password     # 密钥（不设置则随机生成）
```

## 环境变量

| 变量 | 说明 | 默认值 |
|------|------|--------|
| `LISTEN` | 监听地址/端口 | 随机端口 (10000-65535) |
| `PSK` | 预共享密钥 | 随机生成 (32-64位) |
| `IPV6` | 启用 IPv6 | v6+ 默认 true，否则 false |
| `DNS` | DNS 服务器 | `8.8.8.8, 1.1.1.1, 2001:4860:4860::8888, 2606:4700:4700::1111` |
| `DNS_IP_PREFERENCE` | DNS 偏好 (v6+) | `prefer-ipv4` |
| `EGRESS_INTERFACE` | 出口网卡 (v5+) | - |
| `OBFS` | 混淆模式 (v5-) | - |
| `HOST` | 混淆域名 (v5-) | - |

## LISTEN 格式示例

| 写法 | 说明 |
|------|------|
| `20000` | 自动生成 IPv4+IPv6 |
| `20000, 20001` | 多端口 (v6+) |
| `0.0.0.0:20000` | 仅 IPv4 |
| `[::]:20000` | 仅 IPv6 |

## 版本差异

| 版本 | LISTEN 格式 | 多端口 | OBFS/HOST | DNS_IP_PREFERENCE |
|------|-------------|--------|-----------|-------------------|
| v4-v5 | `:::端口` | ❌ | ✅ | ❌ |
| v6+ | `0.0.0.0:端口, [::]:端口` | ✅ | ❌ | ✅ |

## 镜像仓库

```bash
# GHCR
docker pull ghcr.io/cary17/snell:latest

# Docker Hub
docker pull cary17/snell:latest
```

## 查看配置

```bash
docker logs snell
```

输出示例：
```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
[snell-server]
listen = 0.0.0.0:20000, [::]:20000
psk = your_password
ipv6 = true
dns = 8.8.8.8, 1.1.1.1
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

## 注意事项

- 未设置 `PSK` 时，随机密钥会显示在日志中
- 多端口监听需要 v6+，低版本只使用第一个端口
- 桥接模式需用 `LISTEN=0.0.0.0:端口` 才能正确映射端口
```

精简内容：
- 删除了冗余示例和重复说明
- 合并了相似内容
- 简化了表格和格式
- 保留了核心信息和关键用法
