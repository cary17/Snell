# Snell Server Docker

自动构建和发布 Snell Server 的 Docker 镜像，支持多平台架构。

## ✨ 特性

- 🚀 **自动化** - 每小时自动检测新版本并构建
- 🌍 **多平台** - 支持 amd64、i386、arm64、armv7
- 📦 **双仓库** - 同时发布到 GHCR 和 Docker Hub
- 🐧 **精简镜像** - 基于 Debian slim，体积小，占用低
- ⚙️ **灵活配置** - 支持所有 Snell 配置选项
- 💾 **仓库文件构建** - 支持使用仓库中预下载的文件
- 🔑 **Root 权限** - 支持 egress-interface 等需要特权的功能

## 🚀 快速开始

### Docker Run

```bash
docker run -d \
  --name snell \
  -p 20000:20000 \
  -e PSK="your_psk_here" \
  --restart unless-stopped \
  ghcr.io/cary17/snell:latest
```

### Docker Compose

创建 `docker-compose.yml`：

```yaml
version: '3.8'

services:
  snell:
    image: ghcr.io/cary17/snell:latest
    container_name: snell
    restart: unless-stopped
    ports:
      - "20000:20000"
    environment:
      - PSK=your_psk_here_change_me
      - IPV6=false
```

启动服务：

```bash
docker-compose up -d
```

## ⚙️ 配置说明

### 环境变量

| 变量 | 说明 | 默认值 | 是否必需 |
|------|------|--------|----------|
| `PSK` | 预共享密钥 | `RgtvOzILQDPBENgzqeZXsw==` | **建议修改** |
| `PORT` | 监听端口 | `20000` | 否 |
| `IPV6` | 启用 IPv6 | `false` | 否 |
| `LISTEN` | 完整监听配置 | `:::${PORT}` | 否 |
| `DNS` | DNS 服务器（多个用逗号分隔） | - | 否 |
| `EGRESS_INTERFACE` | 出口网络接口（需要 root 权限） | - | 否 |
| `OBFS` | 混淆模式（`http`/`tls`） | - | 否 |
| `HOST` | 混淆主机名 | - | 否 |
| `TFO` | TCP Fast Open | - | 否 |
| `LOG` | 日志级别 | `notify` | 否 |

> **⚠️ 重要提示**: 
> - `egress-interface` 参数需要容器以 root 权限运行（本镜像默认使用 root）
> - 使用 `egress-interface` 时，该接口需要有目标地址和 DNS 的路由表
> - 未配置的可选项不会写入 `snell.conf`，保持配置文件简洁

### 配置示例

#### 最简配置

```yaml
environment:
  - PSK=your_secure_psk_here
```

生成的 `snell.conf`：
```ini
[snell-server]
listen = :::20000
psk = your_secure_psk_here
ipv6 = false
```

#### 完整配置

```yaml
environment:
  - PSK=your_secure_psk
  - PORT=20000
  - IPV6=true
  - DNS=8.8.8.8, 1.0.0.1
  - OBFS=http
  - HOST=example.com
  - TFO=true
```

生成的 `snell.conf`：
```ini
[snell-server]
listen = :::20000
psk = your_secure_psk
ipv6 = true
dns = 8.8.8.8, 1.0.0.1
obfs = http
host = example.com
tfo = true
```

## 📦 镜像仓库

### GHCR (推荐)
```bash
ghcr.io/cary17/snell:latest
ghcr.io/cary17/snell:5.0.1
```

### Docker Hub
```bash
cary17/snell:latest
cary17e/snell:5.0.1
```

### 可用标签

- `latest` - 最新版本
- `5.0.1`, `4.1.1` - 特定版本

### 支持平台

| 平台 | 架构 | 标识 |
|------|------|------|
| x86_64 | amd64 | `linux/amd64` |
| x86 (32位) | i386 | `linux/386` |
| ARM64 | aarch64 | `linux/arm64` |
| ARMv7 | armv7l | `linux/arm/v7` |

## 🔧 手动构建

### 使用 GitHub Actions

1. 进入仓库 **Actions** 页面
2. 选择 **Build and Push Snell Docker Image**
3. 点击 **Run workflow**
4. 填写参数：
   - **version**: 指定版本（留空=最新）
   - **debian**: Debian 版本（默认 `bookworm`）
   - **use_local**: 使用本地文件
   - **force**: 强制重新构建

### 本地构建

```bash
# 构建最新版本
docker build \
  --build-arg SNELL_VERSION=5.0.1 \
  --build-arg DEBIAN_VERSION=bookworm \
  -t snell:5.0.1 \
  .

# 多平台构建
docker buildx build \
  --platform linux/amd64,linux/386,linux/arm64,linux/arm/v7 \
  --build-arg SNELL_VERSION=5.0.1 \
  -t snell:5.0.1 \
  .
```

### 使用仓库文件构建

当官方下载链接不可用时，可以使用仓库中的文件：

```bash
# 1. 下载 Snell 文件到仓库
./download-snell.sh 5.0.1

# 2. 提交到仓库
git add Version/5.0.1/
git commit -m "Add Snell v5.0.1"
git push

# 3. 在 GitHub Actions 中构建
# 勾选 "use_repo_files" 选项
```

详见 [REPO_FILES.md](REPO_FILES.md)

## 📁 项目结构

```
snell-docker/
├── .github/
│   └── workflows/
│       └── build.yml          # 自动化工作流
├── Version/                   # 本地 Snell 文件（可选）
│   ├── 5.0.1/
│   │   ├── snell-server-v5.0.1-linux-amd64.zip
│   │   └── ...
│   └── .gitkeep
├── Dockerfile                 # 多阶段构建定义
├── entrypoint.sh             # 启动脚本
├── docker-compose.yml        # Compose 示例
├── download-snell.sh         # 下载脚本
├── .gitignore
├── README.md
├── LOCAL_FILES.md            # 本地文件使用指南（已废弃）
├── REPO_FILES.md             # 仓库文件使用指南（推荐）
└── SETUP_GUIDE.md           # 详细设置指南
```

## 🛠️ 设置步骤

### 1. 创建 GitHub 仓库

创建私有仓库并上传项目文件。

### 2. 配置 Secrets

在 **Settings → Secrets and variables → Actions** 添加：

- `DOCKER_HUB_USERNAME` - Docker Hub 用户名（可选）
- `DOCKER_HUB_TOKEN` - Docker Hub Token（可选）

> GHCR 使用 `GITHUB_TOKEN`，无需手动配置。

### 3. 配置权限

**Settings → Actions → General → Workflow permissions**
- 选择 **Read and write permissions**

### 4. 首次构建

手动触发 workflow 进行测试构建。

详见 [SETUP_GUIDE.md](SETUP_GUIDE.md)

## 🔍 镜像优化

本项目采用多种优化措施减小镜像体积：

| 优化项 | 说明 |
|--------|------|
| **多阶段构建** | 分离构建和运行环境 |
| **Debian Slim** | 使用精简基础镜像 |
| **清理缓存** | 删除 apt 缓存和临时文件 |
| **Root 运行** | 支持 egress-interface 等特权功能 |
| **最小依赖** | 仅安装必需的 `ca-certificates` |

最终镜像大小：**~80MB** (视平台而异)

## 📊 版本检测

系统每小时检查 [Snell Release Notes](https://kb.nssurge.com/surge-knowledge-base/zh/release-notes/snell)：

1. 解析页面获取最新版本号
2. 检查该版本是否已构建
3. 发现新版本自动触发构建
4. 推送镜像到仓库
5. 创建 GitHub Release

## 🐛 故障排查

### 查看日志

```bash
# 容器日志
docker logs snell

# 实时日志
docker logs -f snell
```

### 查看配置

```bash
# 查看生成的配置文件
docker exec snell cat /snell/snell.conf
```

### 测试连接

```bash
# 检查端口监听
docker exec snell ss -tlnp

# 测试端口
telnet <服务器IP> 20000
```

### 常见问题

#### 容器无法启动

- ✅ 检查端口是否被占用
- ✅ 验证 PSK 配置正确
- ✅ 查看容器日志

#### 无法连接

- ✅ 确认防火墙规则
- ✅ 验证端口映射
- ✅ 检查 PSK 是否匹配
- ✅ 确认客户端配置正确

#### 自动构建失败

- ✅ 检查 GitHub Secrets
- ✅ 查看 Actions 日志
- ✅ 验证下载链接可访问
- ✅ 尝试使用本地文件构建

## 🔐 安全建议

1. **修改默认 PSK** - 使用强随机字符串
2. **定期更新** - 保持使用最新版本
3. **限制访问** - 使用防火墙规则
4. **启用混淆** - 在需要时使用 OBFS
5. **监控日志** - 定期检查异常活动
6. **Root 权限** - 容器使用 root 运行以支持 egress-interface 功能

> **⚠️ 关于 Root 权限**: 
> - 本镜像使用 root 用户运行，因为 `egress-interface` 参数需要 `CAP_NET_RAW`/`CAP_NET_ADMIN` 能力
> - 如果不需要 `egress-interface` 功能，可以考虑添加安全限制
> - 建议配合防火墙和网络隔离使用

### 生成安全的 PSK

```bash
# Linux/macOS
openssl rand -base64 32

# 或使用
head -c 32 /dev/urandom | base64
```

## 📚 相关链接

- [Snell 官方文档](https://manual.nssurge.com/others/snell.html)
- [Snell Release Notes](https://kb.nssurge.com/surge-knowledge-base/zh/release-notes/snell)
- [GitHub Container Registry](https://ghcr.io)
- [Docker Hub](https://hub.docker.com)

## 📝 许可证

本项目仅用于自动化构建 Snell Server 的 Docker 镜像。

Snell Server 版权归 **Surge Networks Inc.** 所有。

## 🤝 贡献

欢迎提交 Issue 和 Pull Request！

## 💬 支持

遇到问题？

1. 查看 [故障排查](#-故障排查) 章节
2. 阅读 [SETUP_GUIDE.md](SETUP_GUIDE.md)
3. 提交 [Issue](../../issues)

---

**⭐ 如果觉得有用，请给项目点个 Star！**
