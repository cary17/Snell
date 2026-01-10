#!/bin/bash

# Snell 下载脚本
# 用法: ./download-snell.sh <版本号>
# 示例: ./download-snell.sh 5.0.1 或 ./download-snell.sh v5.0.1

set -e

INPUT_VERSION="${1}"
if [ -z "$INPUT_VERSION" ]; then
    echo "❌ 错误: 请指定版本号"
    echo ""
    echo "用法: $0 <版本号>"
    echo "示例: $0 5.0.1 或 $0 v5.0.1"
    echo ""
    echo "获取最新版本号: https://kb.nssurge.com/surge-knowledge-base/zh/release-notes/snell"
    exit 1
fi

# 确保版本号有 v 前缀
VERSION="v${INPUT_VERSION#v}"

PLATFORMS=("amd64" "i386" "aarch64" "armv7l")
BASE_URL="https://dl.nssurge.com/snell"
DIR="Version/${VERSION}"

# 创建目录
echo "📁 创建目录: ${DIR}"
mkdir -p "${DIR}"

echo ""
echo "🚀 开始下载 Snell ${VERSION}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

SUCCESS_COUNT=0
FAIL_COUNT=0

# 下载所有平台
for platform in "${PLATFORMS[@]}"; do
    FILE="snell-server-${VERSION}-linux-${platform}.zip"
    URL="${BASE_URL}/${FILE}"
    OUTPUT="${DIR}/${FILE}"
    
    printf "%-10s " "[${platform}]"
    
    if [ -f "${OUTPUT}" ]; then
        echo "⚠️  已存在，跳过"
        ((SUCCESS_COUNT++))
        continue
    fi
    
    if wget -q --show-progress -O "${OUTPUT}" "${URL}" 2>&1; then
        SIZE=$(du -h "${OUTPUT}" | cut -f1)
        echo "✅ 完成 (${SIZE})"
        ((SUCCESS_COUNT++))
    else
        echo "❌ 失败"
        rm -f "${OUTPUT}"
        ((FAIL_COUNT++))
    fi
done

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# 显示结果
if [ $FAIL_COUNT -eq 0 ]; then
    echo "✅ 全部下载成功！($SUCCESS_COUNT/$((SUCCESS_COUNT + FAIL_COUNT)))"
else
    echo "⚠️  部分下载失败 (成功: $SUCCESS_COUNT, 失败: $FAIL_COUNT)"
fi

echo ""
echo "📦 文件列表:"
ls -lh "${DIR}/" 2>/dev/null | tail -n +2 || echo "  (无文件)"

echo ""
echo "💡 下一步:"
echo "  1. 验证文件: unzip -t ${DIR}/snell-server-${VERSION}-linux-amd64.zip"
echo "  2. 本地构建: docker build --build-arg SNELL_VERSION=${VERSION} -t snell:${VERSION} ."
echo "  3. 提交到仓库: git add ${DIR}/ && git commit -m 'Add Snell ${VERSION}' && git push"
