#!/bin/bash
# SEC-AUDITD Alert Engine Launcher
# 支持多个 Python 版本

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_ENGINE="${SCRIPT_DIR}/engine.py"

# 显示使用帮助
show_help() {
    cat << EOF
用法: $0 [选项] <config.yaml>

选项:
  --python-version VERSION, -p VERSION
                        指定 Python 版本 (2.7, 3.5, 3.6, 或默认 3.x)
  --help, -h            显示此帮助信息

示例:
  $0 config.yaml                              # 使用默认 Python 3.x
  $0 --python-version 2.7 config.yaml         # 使用 Python 2.7
  $0 -p 3.5 config.yaml                       # 使用 Python 3.5
  $0 -p 3.6 config.yaml                       # 使用 Python 3.6

支持的 Python 版本:
  - 2.7  : Python 2.7 兼容版本 (使用 py27/engine.py)
  - 3.5  : Python 3.5 兼容版本 (使用 py35/engine.py)
  - 3.6  : Python 3.6 兼容版本 (使用 py36/engine.py)
  - 默认 : Python 3.x 标准版本 (使用 engine.py)

EOF
}

# 解析命令行参数
PYTHON_VERSION=""
CONFIG_FILE=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --python-version|-p)
            PYTHON_VERSION="$2"
            shift 2
            ;;
        --help|-h)
            show_help
            exit 0
            ;;
        *)
            if [[ -z "$CONFIG_FILE" ]]; then
                CONFIG_FILE="$1"
                shift
            else
                echo "错误: 未知参数 '$1'" >&2
                echo "使用 --help 查看帮助" >&2
                exit 1
            fi
            ;;
    esac
done

# 检查配置文件
if [[ -z "$CONFIG_FILE" ]]; then
    echo "错误: 缺少配置文件参数" >&2
    echo "" >&2
    show_help
    exit 1
fi

if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "错误: 配置文件不存在: $CONFIG_FILE" >&2
    exit 1
fi

# 根据 Python 版本选择引擎脚本
ENGINE_SCRIPT=""
PYTHON_CMD=""

case "$PYTHON_VERSION" in
    "2.7"|"27")
        ENGINE_SCRIPT="${SCRIPT_DIR}/py27/engine.py"
        PYTHON_CMD="python2.7"
        if ! command -v python2.7 &> /dev/null; then
            PYTHON_CMD="python2"
            if ! command -v python2 &> /dev/null; then
                echo "错误: Python 2.7 未安装" >&2
                exit 1
            fi
        fi
        ;;
    "3.5"|"35")
        ENGINE_SCRIPT="${SCRIPT_DIR}/py35/engine.py"
        PYTHON_CMD="python3.5"
        if ! command -v python3.5 &> /dev/null; then
            PYTHON_CMD="python3"
            # 检查 Python 3 版本
            if command -v python3 &> /dev/null; then
                PY_VERSION=$(python3 -c 'import sys; print("{}.{}".format(*sys.version_info[:2]))')
                if [[ "$PY_VERSION" < "3.5" ]]; then
                    echo "错误: Python 3.5 或更高版本未安装 (当前: $PY_VERSION)" >&2
                    exit 1
                fi
            else
                echo "错误: Python 3.5 未安装" >&2
                exit 1
            fi
        fi
        ;;
    "3.6"|"36")
        ENGINE_SCRIPT="${SCRIPT_DIR}/py36/engine.py"
        PYTHON_CMD="python3.6"
        if ! command -v python3.6 &> /dev/null; then
            PYTHON_CMD="python3"
            # 检查 Python 3 版本
            if command -v python3 &> /dev/null; then
                PY_VERSION=$(python3 -c 'import sys; print("{}.{}".format(*sys.version_info[:2]))')
                if [[ "$PY_VERSION" < "3.6" ]]; then
                    echo "错误: Python 3.6 或更高版本未安装 (当前: $PY_VERSION)" >&2
                    exit 1
                fi
            else
                echo "错误: Python 3.6 未安装" >&2
                exit 1
            fi
        fi
        ;;
    "")
        # 默认使用标准版本
        ENGINE_SCRIPT="$DEFAULT_ENGINE"
        PYTHON_CMD="python3"
        if ! command -v python3 &> /dev/null; then
            echo "错误: Python 3 未安装" >&2
            exit 1
        fi
        ;;
    *)
        echo "错误: 不支持的 Python 版本: $PYTHON_VERSION" >&2
        echo "支持的版本: 2.7, 3.5, 3.6" >&2
        exit 1
        ;;
esac

# 检查引擎脚本是否存在
if [[ ! -f "$ENGINE_SCRIPT" ]]; then
    echo "错误: 引擎脚本不存在: $ENGINE_SCRIPT" >&2
    exit 1
fi

# 显示启动信息
if [[ -n "$PYTHON_VERSION" ]]; then
    echo "使用 Python $PYTHON_VERSION 版本启动告警引擎"
    echo "引擎脚本: $ENGINE_SCRIPT"
else
    echo "使用默认 Python 版本启动告警引擎"
fi
echo "配置文件: $CONFIG_FILE"
echo ""

# 启动引擎
exec "$PYTHON_CMD" "$ENGINE_SCRIPT" "$CONFIG_FILE"
