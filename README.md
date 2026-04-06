
## 支持平台

- `linux/amd64` - x86_64
- `linux/386` - x86
- `linux/arm64` - ARM 64位
- `linux/arm/v7` - ARM 32位

## 快速开始
```bash
docker run -d \
  --name snell \
  --restart always \
  -p 20000:20000 \
  -e PSK=your_password \
  ghcr.io/cary17/snell:latest
```

## Docker Compose
```yaml
services:
  snell:
    image: ghcr.io/cary17/snell:latest
    container_name: snell
    #user: 1010:1010
    restart: always
    ports:
      - "20000:20000"
    environment:
      - PSK=your_password
      - PORT=20000
      - IPV6=false
```

## 环境变量

| 变量 | 说明 | 默认值 |
|------|------|--------|
| `PORT` | 监听端口 | `20000` |
| `PSK` | 预共享密钥 | 随机生成 |
| `IPV6` | 启用 IPv6 | `false` |
| `LISTEN` | 完整监听配置 | `:::${PORT}` |
| `DNS` | DNS 服务器（多个用逗号分隔，需v4.1.0及以上版本） | - |
| `EGRESS_INTERFACE` | 出口网络接口（需要 root 权限，需v5.0.0及以上版本） | - |
| `OBFS` | 混淆模式（`http`/`tls`）(v4.0.0及以上不建议设置) | - |
| `HOST` | 混淆主机名（设置OBFS后必须设置） | - |

## 可用标签

- `latest` - Latest version
- `vX.Y.Z` - Specific version


## 📦 镜像仓库

### GHCR (推荐)
```bash
ghcr.io/cary17/snell:latest
ghcr.io/cary17/snell:5.0.1
```

### Docker Hub
```bash
cary17/snell:latest
cary17/snell:5.0.1
```
