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

# 安装 Python3
if ! command -v python3 &> /dev/null; then
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
else
    info "✓ python3 已安装"
fi

# 安装 pip3
if [ "$SKIP_ALERT_ENGINE" != "true" ]; then
    if ! command -v pip3 &> /dev/null; then
        warn "pip3 未安装，正在安装..."
        case $PKG_MANAGER in
            apt)
                apt-get install -y python3-pip
                ;;
            yum|dnf)
                python3 -m ensurepip --default-pip || yum install -y python3-pip
                ;;
            zypper)
                zypper install -y python3-pip
                ;;
            *)
                python3 -m ensurepip --default-pip 2>/dev/null || {
                    warn "pip3 安装失败"
                    SKIP_ALERT_ENGINE=true
                }
                ;;
        esac
        if command -v pip3 &> /dev/null; then
            info "✓ pip3 已安装"
        fi
    else
        info "✓ pip3 已安装"
    fi
fi

# 安装 Python 依赖
if [ "$SKIP_ALERT_ENGINE" != "true" ] && [ "$WITH_BINARY" = false ]; then
    info "正在安装 Python 依赖..."
    if [ -f "$REPO_DIR/requirements.txt" ]; then
        pip3 install -q -r "$REPO_DIR/requirements.txt" || {
            warn "部分依赖安装失败，告警引擎可能无法使用"
            SKIP_ALERT_ENGINE=true
        }
    else
        pip3 install -q "PyYAML>=5.1,<7.0" "simpleeval>=0.9.13" || {
            warn "依赖安装失败"
            SKIP_ALERT_ENGINE=true
        }
    fi
    info "✓ Python 依赖已安装"
fi

# 步骤 2: 创建目录结构
step "[2/8] 创建目录结构..."
mkdir -p "$INSTALL_DIR"/{audit.rules.d,alert-engine/rules.d,scripts}
mkdir -p "$LOG_DIR"
info "✓ 目录创建完成"

# 步骤 3: 复制 auditd 规则配置
step "[3/8] 配置 auditd 规则..."
cp -r "$REPO_DIR/audit.rules.d"/* "$INSTALL_DIR/audit.rules.d/" 2>/dev/null || true

# 生成完整的 auditd 规则文件
cat "$INSTALL_DIR/audit.rules.d"/*.rules > /etc/audit/rules.d/sec-auditd.rules
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
    create 0644 root root
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
    if [ "$WITH_BINARY" = true ] && [ -f "$REPO_DIR/dist/engine" ]; then
        info "使用二进制版本"
        cp "$REPO_DIR/dist/engine" "$INSTALL_DIR/alert-engine/"
        chmod +x "$INSTALL_DIR/alert-engine/engine"
        EXEC_CMD="$INSTALL_DIR/alert-engine/engine"
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
augenrules --load 2>/dev/null || auditctl -R /etc/audit/rules.d/sec-auditd.rules
systemctl enable auditd
systemctl restart auditd

# 检查规则加载情况
RULE_COUNT=$(auditctl -l | wc -l)
info "✓ auditd 服务已启动，已加载 $RULE_COUNT 条审计规则"

# 启动告警引擎
if [ "$SKIP_ALERT_ENGINE" != "true" ] && [ "$START_SERVICE" = true ]; then
    if [ "$AUTO_MODE" = true ]; then
        info "自动启动告警引擎..."
        systemctl enable sec-auditd-alert
        systemctl start sec-auditd-alert
        info "✓ 告警引擎已启动"
    else
        read -p "是否现在启动告警引擎？[Y/n] " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Nn]$ ]]; then
            systemctl enable sec-auditd-alert
            systemctl start sec-auditd-alert
            info "✓ 告警引擎已启动"
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
