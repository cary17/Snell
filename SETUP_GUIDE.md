# Snell Docker 设置指南

本指南将帮助你完整设置自动化 Snell Docker 镜像构建系统。

## 前置要求

- GitHub 账号
- Docker Hub 账号（可选，如果只使用 GHCR 可以跳过）
- Git 客户端

## 步骤 1: 创建 GitHub 私有仓库

1. 登录 GitHub
2. 点击右上角的 `+` → `New repository`
3. 填写仓库信息：
   - **Repository name**: `snell-docker`（或你喜欢的名称）
   - **Description**: `自动构建 Snell Server Docker 镜像`
   - **Visibility**: 选择 `Private`（私有仓库）
4. 点击 `Create repository`

## 步骤 2: 上传项目文件

### 方法 1: 使用 Git 命令行

```bash
# 克隆仓库
git clone https://github.com/yourusername/snell-docker.git
cd snell-docker

# 创建必要的目录
mkdir -p .github/workflows

# 创建文件（复制之前提供的内容）
# Dockerfile
# entrypoint.sh
# .github/workflows/build.yml
# docker-compose.yml
# README.md
# .gitignore

# 添加执行权限
chmod +x entrypoint.sh

# 提交文件
git add .
git commit -m "Initial commit: Snell Docker automation"
git push origin main
```

### 方法 2: 使用 GitHub Web 界面

1. 在仓库页面点击 `Add file` → `Create new file`
2. 依次创建以下文件：
   - `Dockerfile`
   - `entrypoint.sh`
   - `.github/workflows/build.yml`
   - `docker-compose.yml`
   - `README.md`
   - `.gitignore`
3. 复制对应的内容并提交

## 步骤 3: 配置 Docker Hub（可选）

如果你想同时推送到 Docker Hub：

1. 登录 [Docker Hub](https://hub.docker.com/)
2. 点击右上角头像 → `Account Settings`
3. 选择 `Security` → `New Access Token`
4. 填写：
   - **Access Token Description**: `GitHub Actions`
   - **Access permissions**: `Read, Write, Delete`
5. 点击 `Generate`
6. **立即复制并保存 Token**（之后无法再查看）

## 步骤 4: 配置 GitHub Secrets

### 4.1 添加 Docker Hub Secrets（如果使用 Docker Hub）

1. 进入 GitHub 仓库
2. 点击 `Settings` → `Secrets and variables` → `Actions`
3. 点击 `New repository secret`
4. 添加以下 secrets：

   **Secret 1:**
   - Name: `DOCKER_HUB_USERNAME`
   - Value: 你的 Docker Hub 用户名

   **Secret 2:**
   - Name: `DOCKER_HUB_TOKEN`
   - Value: 刚才生成的 Docker Hub Token

### 4.2 配置 GitHub Container Registry 权限

1. 在仓库中，进入 `Settings` → `Actions` → `General`
2. 滚动到 `Workflow permissions`
3. 选择 `Read and write permissions`
4. 勾选 `Allow GitHub Actions to create and approve pull requests`
5. 点击 `Save`

## 步骤 5: 修改配置文件

### 5.1 更新 README.md

将以下内容中的 `yourusername` 替换为你的 GitHub 用户名：
- `ghcr.io/yourusername/snell`

### 5.2 更新 docker-compose.yml

将镜像地址更新为你的地址：
```yaml
image: ghcr.io/yourusername/snell:latest
```

## 步骤 6: 首次构建测试

### 6.1 手动触发构建

1. 进入仓库的 `Actions` 页面
2. 选择 `Build and Push Snell Docker Image` workflow
3. 点击 `Run workflow`
4. 保持默认设置（使用最新版本）
5. 点击 `Run workflow` 按钮

### 6.2 监控构建过程

1. 点击运行中的 workflow
2. 查看 `check-version` 和 `build-and-push` 任务
3. 等待构建完成（首次构建可能需要 10-20 分钟）

### 6.3 验证构建结果

构建成功后，你应该能看到：

1. **GitHub Releases**: 仓库的 Releases 页面会有新的 release
2. **GitHub Packages**: 
   - 进入仓库首页，右侧会显示 `Packages`
   - 点击查看镜像信息
3. **Docker Hub**（如果配置了）:
   - 登录 Docker Hub 查看新的镜像

## 步骤 7: 拉取并测试镜像

### 7.1 设置镜像为公开（推荐）

默认情况下，GHCR 的镜像是私有的。要设置为公开：

1. 进入仓库首页
2. 点击右侧的包名（Packages）
3. 点击 `Package settings`
4. 滚动到底部 `Danger Zone`
5. 点击 `Change visibility` → 选择 `Public`

### 7.2 拉取镜像

```bash
# 从 GHCR 拉取
docker pull ghcr.io/yourusername/snell:latest

# 或从 Docker Hub 拉取
docker pull yourusername/snell:latest
```

### 7.3 运行测试

```bash
docker run -d \
  --name snell-test \
  -p 20000:20000 \
  -e PSK="test_psk_123456" \
  ghcr.io/yourusername/snell:latest

# 查看日志
docker logs snell-test

# 查看配置
docker exec snell-test cat /snell/snell.conf

# 停止并删除测试容器
docker stop snell-test && docker rm snell-test
```

## 步骤 8: 验证自动化

### 8.1 定时检查验证

等待 1 小时后，检查 Actions 页面是否有自动运行的 workflow。如果 Snell 没有新版本，workflow 会显示"should_build=false"。

### 8.2 手动验证版本检测

1. 访问 [Snell Release Notes](https://kb.nssurge.com/surge-knowledge-base/zh/release-notes/snell)
2. 记下当前最新版本号
3. 在 Actions 中手动运行 workflow
4. 查看 `check-version` 任务的日志，确认版本号正确

## 常见问题解决

### 问题 1: 构建失败 - "denied: permission_denied"

**原因**: GitHub Actions 没有写入 GHCR 的权限

**解决方法**:
1. 进入 `Settings` → `Actions` → `General`
2. 设置 `Workflow permissions` 为 `Read and write permissions`
3. 重新运行 workflow

### 问题 2: 无法推送到 Docker Hub

**原因**: Docker Hub credentials 配置错误

**解决方法**:
1. 验证 `DOCKER_HUB_USERNAME` 和 `DOCKER_HUB_TOKEN`
2. 重新生成 Docker Hub Token
3. 更新 GitHub Secrets

### 问题 3: 版本检测失败

**原因**: 网页解析规则变化

**解决方法**:
1. 查看 Actions 日志中的错误信息
2. 使用手动指定版本的方式运行 workflow
3. 更新 workflow 中的版本检测逻辑

### 问题 4: 多平台构建失败

**原因**: 特定平台的二进制文件不可用

**解决方法**:
1. 检查 Snell 官方是否提供所有平台的版本
2. 临时移除不可用的平台
3. 等待官方发布

## 生产环境部署

### 1. 创建 docker-compose.yml

```yaml
version: '3.8'

services:
  snell:
    image: ghcr.io/yourusername/snell:latest
    container_name: snell-server
    restart: unless-stopped
    ports:
      - "20000:20000"
    environment:
      - PORT=20000
      - PSK=${SNELL_PSK}  # 从 .env 文件读取
      - IPV6=false
      - DNS=8.8.8.8, 1.0.0.1
      - LOG=notify
```

### 2. 创建 .env 文件

```bash
# .env
SNELL_PSK=your_very_secure_psk_here
```

### 3. 启动服务

```bash
docker-compose up -d
```

### 4. 设置自动更新（可选）

使用 Watchtower 自动更新镜像：

```yaml
version: '3.8'

services:
  snell:
    image: ghcr.io/yourusername/snell:latest
    # ... 其他配置 ...

  watchtower:
    image: containrrr/watchtower
    container_name: watchtower
    restart: unless-stopped
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
    environment:
      - WATCHTOWER_CLEANUP=true
      - WATCHTOWER_POLL_INTERVAL=3600  # 每小时检查一次
```

## 维护和更新

### 更新 Debian 基础镜像版本

当新的 Debian 版本发布时（如 Debian 13）：

1. 手动触发 workflow
2. 在 `debian_version` 字段填入新版本名称（如 `trixie`）
3. 运行构建

### 手动构建特定版本

1. 进入 Actions 页面
2. 运行 workflow
3. 填写参数：
   - `snell_version`: 如 `4.1.1`
   - `debian_version`: 如 `bookworm`
   - 勾选 `force_build` 强制重新构建

### 查看构建历史

1. 进入 Actions 页面
2. 查看所有 workflow 运行记录
3. 点击任意运行查看详细日志

## 安全建议

1. **保护 Secrets**: 永远不要在代码中硬编码密钥
2. **定期更新 PSK**: 定期更改 Snell 的 PSK
3. **使用强密码**: PSK 应该使用强随机字符串
4. **限制访问**: 使用防火墙限制访问来源
5. **监控日志**: 定期检查容器日志异常活动

## 下一步

现在你的自动化 Snell Docker 构建系统已经设置完成！系统会：

- ✅ 每小时自动检查新版本
- ✅ 发现新版本时自动构建
- ✅ 推送到 GHCR 和 Docker Hub
- ✅ 创建 GitHub Release
- ✅ 支持多平台架构

如有问题，请查看：
- GitHub Actions 日志
- 本仓库的 Issues
- Snell 官方文档

祝使用愉快！
