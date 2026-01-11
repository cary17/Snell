# Snell Server Docker Image

Multi-architecture Snell Server Docker image with automatic builds.

## Supported Architectures

- `linux/amd64` - x86_64
- `linux/386` - x86
- `linux/arm64` - ARM 64位
- `linux/arm/v7` - ARM 32位

## Quick Start
```bash
docker run -d \
  --name snell \
  --restart unless-stopped \
  -p 20000:20000 \
  -e PSK=your_password \
  ghcr.io/OWNER/snell:latest
```

## Docker Compose
```yaml
services:
  snell:
    image: ghcr.io/OWNER/snell:latest
    container_name: snell
    restart: unless-stopped
    ports:
      - "20000:20000"
    environment:
      - PSK=your_password
      - PORT=20000
      - IPV6=false
```

## Environment Variables

| Variable | Description | Default | Required |
|----------|-------------|---------|----------|
| `PSK` | Pre-shared key (password) | Random | No |
| `PORT` | Listen port | `20000` | No |
| `LISTEN` | Listen address | `:::${PORT}` | No |
| `IPV6` | Enable IPv6 | `false` | No |
| `DNS` | Custom DNS servers | - | No |
| `OBFS` | Obfuscation mode (`http`, `tls`) | - | No |
| `HOST` | Obfuscation host (with `OBFS`) | - | No |
| `EGRESS_INTERFACE` | Egress network interface | - | No |
| `LOG` | Log level | `notify` | No |

## Available Tags

- `latest` - Latest version
- `vX.Y.Z` - Specific version

## Full Documentation

Complete documentation, examples, and troubleshooting guide available at:
**https://github.com/OWNER/REPO**

## License

Docker packaging only. Snell Server © [Surge Networks Inc.](https://nssurge.com/)
