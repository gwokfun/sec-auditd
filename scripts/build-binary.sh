#!/bin/bash
# SEC-AUDITD 二进制打包脚本
# 使用 PyInstaller 将 engine.py 打包为独立的二进制文件

set -e

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

step() {
    echo -e "${BLUE}[STEP]${NC} $1"
}

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$REPO_DIR/build"
DIST_DIR="$REPO_DIR/dist"
ENGINE_PY="$REPO_DIR/alert-engine/engine.py"

echo "======================================"
echo "  SEC-AUDITD 二进制打包脚本"
echo "======================================"
echo ""

# 检查 Python3
if ! command -v python3 &> /dev/null; then
    error "python3 未安装"
    exit 1
fi

info "Python 版本: $(python3 --version)"

# 步骤 1: 安装 PyInstaller
step "[1/4] 检查 PyInstaller..."
if ! python3 -m pip show pyinstaller &> /dev/null; then
    info "PyInstaller 未安装，正在安装..."
    python3 -m pip install pyinstaller
    info "✓ PyInstaller 已安装"
else
    info "✓ PyInstaller 已安装"
fi

# 步骤 2: 安装依赖
step "[2/4] 安装依赖..."
if [ -f "$REPO_DIR/requirements.txt" ]; then
    python3 -m pip install -r "$REPO_DIR/requirements.txt"
    info "✓ 依赖已安装"
else
    warn "requirements.txt 未找到"
fi

# 步骤 3: 打包
step "[3/4] 打包二进制文件..."
info "开始打包，这可能需要几分钟..."

cd "$REPO_DIR"

# 清理之前的构建
rm -rf "$BUILD_DIR" "$DIST_DIR"

# 使用 PyInstaller 打包
python3 -m PyInstaller \
    --onefile \
    --name sec-auditd-engine \
    --clean \
    --noconfirm \
    --log-level WARN \
    --add-data "alert-engine/config.yaml:." \
    --hidden-import=yaml \
    --hidden-import=simpleeval \
    --hidden-import=logging \
    --hidden-import=json \
    --hidden-import=re \
    --hidden-import=collections \
    "$ENGINE_PY"

if [ -f "$DIST_DIR/sec-auditd-engine" ]; then
    info "✓ 打包成功"

    # 显示文件信息
    FILE_SIZE=$(du -h "$DIST_DIR/sec-auditd-engine" | cut -f1)
    info "二进制文件大小: $FILE_SIZE"
    info "二进制文件位置: $DIST_DIR/sec-auditd-engine"
else
    error "打包失败"
    exit 1
fi

# 步骤 4: 测试二进制文件
step "[4/4] 测试二进制文件..."
if "$DIST_DIR/sec-auditd-engine" --help &> /dev/null || true; then
    info "✓ 二进制文件可执行"
else
    warn "二进制文件测试未通过，但文件已生成"
fi

# 清理构建文件
info "清理构建文件..."
rm -rf "$BUILD_DIR"
rm -f "$REPO_DIR/sec-auditd-engine.spec"
info "✓ 清理完成"

echo ""
echo "======================================"
echo "  打包完成！"
echo "======================================"
echo ""
echo "二进制文件:"
echo "  $DIST_DIR/sec-auditd-engine"
echo ""
echo "使用方法:"
echo "  $DIST_DIR/sec-auditd-engine <config.yaml>"
echo ""
echo "部署方法:"
echo "  1. 复制二进制文件到目标系统"
echo "  2. 使用 --with-binary 参数安装:"
echo "     sudo ./scripts/quick-install.sh --with-binary"
echo ""
echo "注意事项:"
echo "  - 二进制文件仅适用于相同的 Linux 架构"
echo "  - 建议在目标系统类似的环境中构建"
echo "  - 配置文件和规则文件仍需单独部署"
echo ""
