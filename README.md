以下是修改后的 README 文档：

```markdown
# Snell Server Docker Image

支持 Snell v3 到 v6+ 版本的 Docker 镜像，自动适配不同版本的配置格式。

## 支持平台

- `linux/amd64` - x86_64
- `linux/386` - x86
- `linux/arm64` - ARM 64位
- `linux/arm/v7` - ARM 32位

## 快速开始

### 基础使用（单端口）
```bash
docker run -d \
  --name snell \
  --restart always \
  -p 20000:20000 \
  -e LISTEN=20000 \
  -e PSK=your_password \
  ghcr.io/cary17/snell:latest
```

### 多端口监听（v6+）
```bash
docker run -d \
  --name snell \
  --restart always \
  -p 20000:20000 \
  -p 20001:20001 \
  -p 20002:20002 \
  -e LISTEN="20000, 20001, 20002" \
  -e PSK=your_password \
  ghcr.io/cary17/snell:latest
```

### 仅 IPv4
```bash
docker run -d \
  --name snell \
  --restart always \
  -p 20000:20000 \
  -e LISTEN="0.0.0.0:20000" \
  -e PSK=your_password \
  ghcr.io/cary17/snell:latest
```

### 仅 IPv6
```bash
docker run -d \
  --name snell \
  --restart always \
  -p 20000:20000 \
  -e LISTEN="[::]:20000" \
  -e IPV6=true \
  -e PSK=your_password \
  ghcr.io/cary17/snell:latest
```

## Docker Compose 示例

### 基础配置
```yaml
services:
  snell:
    image: ghcr.io/cary17/snell:latest
    container_name: snell
    restart: always
    ports:
      - "20000:20000"
    environment:
      - LISTEN=20000
      - PSK=your_password
      - TZ=Asia/Shanghai
```

### 多端口配置（v6+）
```yaml
services:
  snell:
    image: ghcr.io/cary17/snell:latest
    container_name: snell
    restart: always
    ports:
      - "20000:20000"
      - "20001:20001"
      - "20002:20002"
    environment:
      - LISTEN=20000, 20001, 20002
      - PSK=your_password
      - DNS=8.8.8.8, 1.1.1.1
      - DNS_IP_PREFERENCE=prefer-ipv4
      - TZ=Asia/Shanghai
```

### host 网络模式（性能最佳）
```yaml
services:
  snell:
    image: ghcr.io/cary17/snell:latest
    container_name: snell
    restart: always
    network_mode: "host"
    environment:
      - LISTEN=20000
      - PSK=your_password
      - EGRESS_INTERFACE=eth0
      - TZ=Asia/Shanghai
```

### 带混淆配置
```yaml
services:
  snell:
    image: ghcr.io/cary17/snell:latest
    container_name: snell
    restart: always
    ports:
      - "20000:20000"
    environment:
      - LISTEN=20000
      - PSK=your_password
      - OBFS=http
      - HOST=cloudflare.com
```

## 环境变量

| 变量 | 说明 | 默认值 |
|------|------|--------|
| `LISTEN` | 监听地址/端口（推荐），支持多种格式（见下方说明） | `20000` |
| `PSK` | 预共享密钥（必填） | 随机生成 |
| `IPV6` | 启用 IPv6 | `false` |
| `DNS` | DNS 服务器，多个用逗号分隔 | - |
| `DNS_IP_PREFERENCE` | DNS 解析 IP 地址族偏好（`prefer-ipv4`/`prefer-ipv6`/`ipv4-only`/`ipv6-only`） | - |
| `EGRESS_INTERFACE` | 出口网络接口（需要 root 权限） | - |
| `OBFS` | 混淆模式（`http`/`tls`） | - |
| `HOST` | 混淆主机名（设置 OBFS 后必须设置） | - |
| `LOG` | 日志级别（`notify`/`debug`/`info`/`warn`/`error`） | `notify` |
| `TZ` | 时区 | - |

## LISTEN 配置格式

### 1. 仅端口号（自动生成 IPv4+IPv6）
```yaml
- LISTEN=20000
# 生成: 0.0.0.0:20000, [::]:20000
```

### 2. 多端口（自动生成 IPv4+IPv6，v6+ 支持）
```yaml
- LISTEN=20000, 20001, 20002
# 生成: 0.0.0.0:20000, [::]:20000, 0.0.0.0:20001, [::]:20001, 0.0.0.0:20002, [::]:20002
```

### 3. 仅 IPv4
```yaml
- LISTEN=0.0.0.0:20000
# 生成: 0.0.0.0:20000
```

### 4. 仅 IPv6
```yaml
- LISTEN=[::]:20000
# 生成: [::]:20000
```

### 5. 混合格式
```yaml
- LISTEN=0.0.0.0:20000, 20001
# 生成: 0.0.0.0:20000, 0.0.0.0:20001, [::]:20001
```

## 版本兼容性

| 版本 | 下载源 | LISTEN 格式 | 多端口支持 |
|------|--------|-------------|-----------|
| v3 | 本地仓库 | `0.0.0.0:端口` | ❌ |
| v4/v5 | 官网 | `:::端口` (双栈) | ❌ |
| v6+ | 官网 | `0.0.0.0:端口, [::]:端口` | ✅ |

镜像会自动检测 Snell 版本并使用对应的配置格式。

## 可用标签

- `latest` - 最新版本
- `v3.0.1` - Snell v3 版本
- `v4.0.1` - Snell v4 版本
- `v5.0.1` - Snell v5 版本
- `v6.0.0` - Snell v6 版本

## 📦 镜像仓库

### GHCR (推荐)
```bash
# 拉取最新版本
docker pull ghcr.io/cary17/snell:latest

# 拉取指定版本
docker pull ghcr.io/cary17/snell:v6.0.0
```

### Docker Hub
```bash
# 拉取最新版本
docker pull cary17/snell:latest

# 拉取指定版本
docker pull cary17/snell:v6.0.0
```

## 查看日志

```bash
# 查看容器日志
docker logs snell

# 实时查看日志
docker logs -f snell
```

日志会显示生成的配置和 Snell 运行状态：
```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
[snell-server]
listen = 0.0.0.0:20000, [::]:20000
psk = your_password
ipv6 = false
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Starting snell-server...
```

## 注意事项

1. **PSK 未设置时**：会自动生成随机密钥，在容器日志中查看
2. **多端口监听**：需要 v6.0.0 及以上版本，低版本只使用第一个端口
3. **host 网络模式**：使用 `network_mode: "host"` 时不需要端口映射
4. **桥接模式**：需要设置 `LISTEN=0.0.0.0:端口` 才能正确映射端口
5. **IPv6 支持**：需要同时设置 `LISTEN=[::]:端口` 和 `IPV6=true`

## 更新镜像

```bash
# 拉取最新镜像
docker pull ghcr.io/cary17/snell:latest

# 重新创建容器
docker rm -f snell
docker run -d --name snell ... ghcr.io/cary17/snell:latest
```
```

主要修改内容：

1. **移除 `PORT` 变量**，统一使用 `LISTEN`
2. **更新快速开始示例**，展示单端口和多端口的用法
3. **增加 LISTEN 配置格式说明**，详细列出各种写法
4. **更新 Docker Compose 示例**，增加多端口和 host 网络模式
5. **添加版本兼容性表格**，说明不同版本的区别
6. **增加注意事项**，帮助用户避免常见问题
7. **更新可用标签**，包含 v3-v6 版本示例
