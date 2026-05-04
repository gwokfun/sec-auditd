#!/bin/bash
# SEC-AUDITD 一键快速安装脚本
# 自动检测和安装依赖，支持多种包管理器

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

# 默认参数
AUTO_MODE=false
MINIMAL_MODE=false
WITH_BINARY=false
USE_BINARY=false
SKIP_ALERT_ENGINE=false
START_SERVICE=true
PYTHON_VERSION=""

# 解析命令行参数
while [[ $# -gt 0 ]]; do
    case $1 in
        --auto|-a)
            AUTO_MODE=true
            shift
            ;;
        --minimal|-m)
            MINIMAL_MODE=true
            shift
            ;;
        --with-binary|-b)
            WITH_BINARY=true
            shift
            ;;
        --no-start)
            START_SERVICE=false
            shift
            ;;
        --python-version|-p)
            PYTHON_VERSION="$2"
            shift 2
            ;;
        --help|-h)
            echo "用法: $0 [选项]"
            echo ""
            echo "选项:"
            echo "  --auto, -a                    自动模式，跳过所有交互"
            echo "  --minimal, -m                 最小化安装，仅安装核心组件"
            echo "  --with-binary, -b             使用二进制版本（如果可用）"
            echo "  --python-version VERSION, -p  指定 Python 版本 (2.7, 3.5, 3.6, 或默认 3.x)"
            echo "  --no-start                    安装后不启动服务"
            echo "  --help, -h                    显示此帮助信息"
            echo ""
            echo "示例:"
            echo "  $0 --auto                              # 全自动安装"
            echo "  $0 --minimal --auto                    # 最小化自动安装"
            echo "  $0 --with-binary --auto                # 使用二进制版本安装"
            echo "  $0 --python-version 2.7 --auto         # 使用 Python 2.7"
            echo "  $0 -p 3.6 --auto                       # 使用 Python 3.6"
            exit 0
            ;;
        *)
            error "未知选项: $1"
            echo "使用 --help 查看帮助"
            exit 1
            ;;
    esac
done

INSTALL_DIR="/etc/sec-auditd"
LOG_DIR="/var/log/sec-auditd"
VENV_DIR="$INSTALL_DIR/venv"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "======================================"
echo "  SEC-AUDITD 快速安装脚本"
echo "======================================"
echo ""

# 检查权限
if [ "$EUID" -ne 0 ]; then
    error "需要 root 权限运行此脚本"
    echo "请使用: sudo $0"
    exit 1
fi

# 检测包管理器
detect_package_manager() {
    if command -v apt-get &> /dev/null; then
        echo "apt"
    elif command -v yum &> /dev/null; then
        echo "yum"
    elif command -v dnf &> /dev/null; then
        echo "dnf"
    elif command -v zypper &> /dev/null; then
        echo "zypper"
    else
        echo "unknown"
    fi
}

PKG_MANAGER=$(detect_package_manager)
info "检测到包管理器: $PKG_MANAGER"

if [ "$WITH_BINARY" = true ]; then
    if [ -f "$REPO_DIR/dist/engine" ]; then
        USE_BINARY=true
        info "检测到二进制引擎，将跳过 Python 运行时依赖"
    else
        warn "指定了 --with-binary，但未找到 $REPO_DIR/dist/engine，将回退到 Python 脚本模式"
    fi
fi

# 步骤 1: 安装依赖
step "[1/8] 检查和安装依赖..."

# 安装 auditd
if ! command -v auditctl &> /dev/null; then
    warn "auditd 未安装，正在安装..."
    case $PKG_MANAGER in
        apt)
            apt-get update -qq
            apt-get install -y auditd
            ;;
        yum)
            yum install -y audit
            ;;
        dnf)
            dnf install -y audit
            ;;
        zypper)
            zypper install -y audit
            ;;
        *)
            error "无法自动安装 auditd，请手动安装"
            exit 1
            ;;
    esac
    info "✓ auditd 已安装"
else
    info "✓ auditd 已安装"
fi

# 安装 Python3（二进制模式不需要）
if [ "$USE_BINARY" != true ] && ! command -v python3 &> /dev/null; then
    warn "python3 未安装，正在安装..."
    case $PKG_MANAGER in
        apt)
            apt-get install -y python3 python3-pip
            ;;
        yum)
            yum install -y python3 python3-pip
            ;;
        dnf)
            dnf install -y python3 python3-pip
            ;;
        zypper)
            zypper install -y python3 python3-pip
            ;;
        *)
            error "无法自动安装 python3，请手动安装"
            SKIP_ALERT_ENGINE=true
            ;;
    esac
    if command -v python3 &> /dev/null; then
        info "✓ python3 已安装"
    fi
elif [ "$USE_BINARY" != true ]; then
    info "✓ python3 已安装"
fi

# 步骤 2: 创建目录结构
step "[2/8] 创建目录结构..."
mkdir -p "$INSTALL_DIR"/{audit.rules.d,alert-engine/rules.d,scripts}
mkdir -p "$LOG_DIR"
info "✓ 目录创建完成"

install_venv_support() {
    case $PKG_MANAGER in
        apt)
            apt-get install -y python3-venv
            ;;
        yum)
            yum install -y python3-virtualenv python3-pip
            ;;
        dnf)
            dnf install -y python3-virtualenv python3-pip
            ;;
        zypper)
            zypper install -y python3-virtualenv python3-pip
            ;;
        *)
            return 1
            ;;
    esac
}

create_python_venv() {
    local python_cmd="$1"
    rm -rf "$VENV_DIR"
    "$python_cmd" -m venv "$VENV_DIR" 2>/dev/null || {
        warn "创建 Python venv 失败，尝试安装 venv 支持包..."
        install_venv_support || return 1
        "$python_cmd" -m venv "$VENV_DIR"
    }
    "$VENV_DIR/bin/python" -m ensurepip --upgrade >/dev/null 2>&1 || true
    "$VENV_DIR/bin/python" -m pip install -q --upgrade pip
}

# 安装 Python 依赖到隔离 venv，避免修改系统 Python 包
if [ "$SKIP_ALERT_ENGINE" != "true" ] && [ "$USE_BINARY" != true ]; then
    info "正在创建 Python 虚拟环境并安装依赖..."

    VENV_PYTHON="python3"
    case "$PYTHON_VERSION" in
        "3.5"|"35")
            command -v python3.5 >/dev/null 2>&1 && VENV_PYTHON="python3.5"
            ;;
        "3.6"|"36")
            command -v python3.6 >/dev/null 2>&1 && VENV_PYTHON="python3.6"
            ;;
        "2.7"|"27")
            warn "Python 2.7 模式不支持 venv 安装；请预先安装 PyYAML 和 simpleeval"
            ;;
    esac

    if [ "$PYTHON_VERSION" = "2.7" ] || [ "$PYTHON_VERSION" = "27" ]; then
        info "✓ 跳过 venv 创建（Python 2.7 模式）"
    elif create_python_venv "$VENV_PYTHON"; then
        if [ -f "$REPO_DIR/requirements.txt" ]; then
            "$VENV_DIR/bin/python" -m pip install -q -r "$REPO_DIR/requirements.txt" || SKIP_ALERT_ENGINE=true
        else
            "$VENV_DIR/bin/python" -m pip install -q "PyYAML>=5.1,<7.0" "simpleeval>=0.9.13" || SKIP_ALERT_ENGINE=true
        fi
        if [ "$SKIP_ALERT_ENGINE" != "true" ]; then
            info "✓ Python 依赖已安装到 $VENV_DIR"
        fi
    else
        warn "创建 Python 虚拟环境失败，告警引擎将无法使用"
        SKIP_ALERT_ENGINE=true
    fi
fi

# 步骤 3: 复制 auditd 规则配置
step "[3/8] 配置 auditd 规则..."
cp -r "$REPO_DIR/audit.rules.d"/* "$INSTALL_DIR/audit.rules.d/" 2>/dev/null || true

# 生成完整的 auditd 规则文件（过滤不存在的路径）
generate_rules() {
    cat "$INSTALL_DIR/audit.rules.d"/*.rules | while IFS= read -r line; do
        # 跳过空行和注释
        [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && echo "$line" && continue
        # 对 -w 规则检查路径是否存在
        if [[ "$line" =~ ^[[:space:]]*-w[[:space:]]+([^[:space:]]+) ]]; then
            local path="${BASH_REMATCH[1]}"
            if [ ! -e "$path" ]; then
                echo "# SKIPPED (path not found: $path): $line"
                continue
            fi
        fi
        echo "$line"
    done
}
generate_rules > /etc/audit/rules.d/sec-auditd.rules
info "✓ 规则文件已生成: /etc/audit/rules.d/sec-auditd.rules"

# 步骤 4: 配置日志轮转
step "[4/8] 配置日志轮转..."
cat > /etc/logrotate.d/sec-auditd <<'EOF'
# Auditd 日志轮转
/var/log/audit/audit.log {
    daily
    rotate 30
    compress
    delaycompress
    missingok
    notifempty
    create 0600 root root
    postrotate
        /sbin/service auditd reload > /dev/null 2>&1 || true
    endscript
    size 100M
    dateext
    dateformat -%Y%m%d-%s
}

# 告警日志轮转
/var/log/sec-auditd/alert.log {
    daily
    rotate 30
    compress
    delaycompress
    missingok
    notifempty
    create 0600 root root
    size 50M
    dateext
    dateformat -%Y%m%d-%s
}
EOF
info "✓ 日志轮转配置完成"

# 步骤 5: 安装告警引擎
step "[5/8] 安装告警引擎..."
if [ "$SKIP_ALERT_ENGINE" != "true" ]; then
    cp -r "$REPO_DIR/alert-engine"/* "$INSTALL_DIR/alert-engine/"
    chmod +x "$INSTALL_DIR/alert-engine/launch-engine.sh"

    # 选择执行方式
    if [ "$USE_BINARY" = true ]; then
        info "使用二进制版本"
        cp "$REPO_DIR/dist/engine" "$INSTALL_DIR/alert-engine/"
        chmod +x "$INSTALL_DIR/alert-engine/engine"
        EXEC_CMD="$INSTALL_DIR/alert-engine/engine"
    elif [ -z "$PYTHON_VERSION" ]; then
        EXEC_CMD="$VENV_DIR/bin/python $INSTALL_DIR/alert-engine/engine.py"
    elif [ "$PYTHON_VERSION" = "3.5" ] || [ "$PYTHON_VERSION" = "35" ]; then
        info "配置使用 Python 3.5 兼容引擎"
        EXEC_CMD="$VENV_DIR/bin/python $INSTALL_DIR/alert-engine/py35/engine.py"
    elif [ "$PYTHON_VERSION" = "3.6" ] || [ "$PYTHON_VERSION" = "36" ]; then
        info "配置使用 Python 3.6 兼容引擎"
        EXEC_CMD="$VENV_DIR/bin/python $INSTALL_DIR/alert-engine/py36/engine.py"
    else
        # 使用 launch-engine.sh 脚本启动，支持 Python 版本选择
        if [ -n "$PYTHON_VERSION" ]; then
            info "配置使用 Python $PYTHON_VERSION"
            EXEC_CMD="$INSTALL_DIR/alert-engine/launch-engine.sh --python-version $PYTHON_VERSION"
        else
            EXEC_CMD="$INSTALL_DIR/alert-engine/launch-engine.sh"
        fi
    fi

    # 创建 systemd 服务
    cat > /etc/systemd/system/sec-auditd-alert.service <<EOF
[Unit]
Description=SEC-AUDITD Alert Engine
Documentation=https://github.com/gwokfun/sec-auditd
After=auditd.service
Requires=auditd.service

[Service]
Type=simple
User=root
ExecStart=$EXEC_CMD $INSTALL_DIR/alert-engine/config.yaml
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    info "✓ 告警引擎已安装"
else
    warn "⚠ 跳过告警引擎安装（缺少依赖）"
fi

# 步骤 6: 安装辅助脚本
step "[6/8] 安装辅助脚本..."
cp "$REPO_DIR/scripts"/* "$INSTALL_DIR/scripts/" 2>/dev/null || true
chmod +x "$INSTALL_DIR/scripts"/*.sh 2>/dev/null || true
info "✓ 脚本已安装到 $INSTALL_DIR/scripts/"

# 步骤 7: 配置 cgroups 资源限制（可选）
step "[7/8] 配置资源限制..."
if [ "$MINIMAL_MODE" = false ] && [ "$SKIP_ALERT_ENGINE" != "true" ]; then
    if [ -f "$INSTALL_DIR/scripts/setup-cgroups.sh" ]; then
        info "配置 cgroups 资源限制..."
        bash "$INSTALL_DIR/scripts/setup-cgroups.sh" || warn "cgroups 配置失败，继续安装"
        info "✓ 资源限制已配置"
    fi
else
    info "跳过资源限制配置"
fi

# 步骤 8: 启动服务
step "[8/8] 启动服务..."

# 启动 auditd
info "启动 auditd 服务..."
# 先删除旧规则再加载
auditctl -D 2>/dev/null || true
if ! augenrules --load; then
    warn "augenrules 加载失败，尝试直接加载规则..."
    if ! auditctl -R /etc/audit/rules.d/sec-auditd.rules; then
        error "审计规则加载失败，请检查 /etc/audit/rules.d/sec-auditd.rules"
        exit 1
    fi
fi
systemctl enable auditd
systemctl restart auditd

# 检查规则加载情况
RULE_COUNT=$(auditctl -l 2>/dev/null | wc -l)
if [ "$RULE_COUNT" -eq 0 ]; then
    error "审计规则加载后数量为 0，安装中止"
    exit 1
fi
info "✓ auditd 服务已启动，已加载 $RULE_COUNT 条审计规则"

# 启动告警引擎
if [ "$SKIP_ALERT_ENGINE" != "true" ] && [ "$START_SERVICE" = true ]; then
    # 确保引擎文件已安装（幂等）
    if [ ! -f "$INSTALL_DIR/alert-engine/engine.py" ]; then
        cp -r "$REPO_DIR/alert-engine"/* "$INSTALL_DIR/alert-engine/" 2>/dev/null || true
        chmod +x "$INSTALL_DIR/alert-engine/launch-engine.sh" 2>/dev/null || true
        systemctl daemon-reload
    fi

    if [ "$AUTO_MODE" = true ]; then
        info "自动启动告警引擎..."
        systemctl enable sec-auditd-alert
        systemctl restart sec-auditd-alert
        sleep 1
        if systemctl is-active --quiet sec-auditd-alert; then
            info "✓ 告警引擎已启动"
        else
            warn "告警引擎启动失败，请检查: journalctl -u sec-auditd-alert"
        fi
    else
        read -p "是否现在启动告警引擎？[Y/n] " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Nn]$ ]]; then
            systemctl enable sec-auditd-alert
            systemctl restart sec-auditd-alert
            sleep 1
            if systemctl is-active --quiet sec-auditd-alert; then
                info "✓ 告警引擎已启动"
            else
                warn "告警引擎启动失败，请检查: journalctl -u sec-auditd-alert"
            fi
        else
            info "您可以稍后使用以下命令启动："
            echo "  systemctl start sec-auditd-alert"
        fi
    fi
fi

echo ""
echo "======================================"
echo "  安装完成！"
echo "======================================"
echo ""
echo "配置位置："
echo "  - 安装目录: $INSTALL_DIR"
echo "  - 审计规则: /etc/audit/rules.d/sec-auditd.rules"
echo "  - 审计日志: /var/log/audit/audit.log"
echo "  - 告警日志: $LOG_DIR/alert.log"
echo ""
echo "管理命令："
echo "  - 查看规则: auditctl -l"
echo "  - 查看日志: ausearch -ts recent -i"
echo "  - 检查状态: $INSTALL_DIR/scripts/check-audit.sh"
echo ""

if [ "$SKIP_ALERT_ENGINE" != "true" ]; then
    echo "告警引擎："
    echo "  - 查看状态: systemctl status sec-auditd-alert"
    echo "  - 查看日志: journalctl -u sec-auditd-alert -f"
    echo "  - 查看告警: tail -f $LOG_DIR/alert.log"
    echo ""
fi

echo "下一步建议："
echo "  1. 根据实际需求调整规则: $INSTALL_DIR/audit.rules.d/"
echo "  2. 自定义告警规则: $INSTALL_DIR/alert-engine/rules.d/"
echo "  3. 测试规则配置: $INSTALL_DIR/scripts/test-rules.sh"
if [ "$SKIP_ALERT_ENGINE" != "true" ]; then
    echo "  4. 配置日志采集（Filebeat/Fluentd 等）"
fi
echo ""
