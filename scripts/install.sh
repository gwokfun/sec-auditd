#!/bin/bash
# SEC-AUDITD 安装脚本
# 用于部署 auditd 规则和告警引擎

set -e

# 默认参数
PYTHON_VERSION=""

# 解析命令行参数
while [[ $# -gt 0 ]]; do
    case $1 in
        --python-version|-p)
            PYTHON_VERSION="$2"
            shift 2
            ;;
        --help|-h)
            echo "用法: $0 [选项]"
            echo ""
            echo "选项:"
            echo "  --python-version VERSION, -p  指定 Python 版本 (2.7, 3.5, 3.6, 或默认 3.x)"
            echo "  --help, -h                    显示此帮助信息"
            echo ""
            echo "示例:"
            echo "  $0                            # 使用默认 Python 版本"
            echo "  $0 --python-version 2.7       # 使用 Python 2.7"
            echo "  $0 -p 3.6                     # 使用 Python 3.6"
            exit 0
            ;;
        *)
            echo "错误：未知选项 '$1'"
            echo "使用 --help 查看帮助"
            exit 1
            ;;
    esac
done

INSTALL_DIR="/etc/sec-auditd"
LOG_DIR="/var/log/sec-auditd"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "======================================"
echo "  SEC-AUDITD 安装脚本"
echo "======================================"
echo ""

# 检查权限
if [ "$EUID" -ne 0 ]; then
    echo "错误：需要 root 权限运行此脚本"
    echo "请使用: sudo $0"
    exit 1
fi

# 检查 auditd 是否安装
if ! command -v auditctl &> /dev/null; then
    echo "错误：auditd 未安装"
    echo ""
    echo "请先安装 auditd："
    echo "  CentOS/RHEL: yum install audit"
    echo "  Ubuntu/Debian: apt-get install auditd"
    echo "  Fedora: dnf install audit"
    exit 1
fi

echo "[1/7] 检查依赖..."
echo "✓ auditd 已安装"

# 检查 Python3
if ! command -v python3 &> /dev/null; then
    echo "警告：python3 未安装，告警引擎需要 python3"
    echo "如需使用告警引擎，请安装: apt-get install python3 python3-pip"
    SKIP_ALERT_ENGINE=1
else
    echo "✓ python3 已安装"
    # 检查 pip
    if ! command -v pip3 &> /dev/null; then
        echo "警告：pip3 未安装"
        echo "正在尝试安装 pip3..."
        python3 -m ensurepip --default-pip 2>/dev/null || {
            echo "pip3 安装失败，告警引擎将无法使用"
            SKIP_ALERT_ENGINE=1
        }
    fi
    # 安装依赖
    if [ -z "$SKIP_ALERT_ENGINE" ]; then
        echo "正在安装 Python 依赖..."
        if [ -f "$REPO_DIR/requirements.txt" ]; then
            pip3 install -r "$REPO_DIR/requirements.txt" || {
                echo "依赖安装失败，告警引擎将无法使用"
                SKIP_ALERT_ENGINE=1
            }
        else
            # 手动安装核心依赖
            pip3 install "PyYAML>=5.1,<7.0" "simpleeval>=0.9.13" || {
                echo "依赖安装失败，告警引擎将无法使用"
                SKIP_ALERT_ENGINE=1
            }
        fi
        echo "✓ Python 依赖已安装"
    fi
fi

echo ""
echo "[2/7] 创建目录结构..."
mkdir -p "$INSTALL_DIR"/{audit.rules.d,alert-engine/rules.d,scripts}
mkdir -p "$LOG_DIR"
echo "✓ 目录创建完成"

echo ""
echo "[3/7] 复制 auditd 规则配置..."
cp -r "$REPO_DIR/audit.rules.d"/* "$INSTALL_DIR/audit.rules.d/" 2>/dev/null || true

# 生成完整的 auditd 规则文件
echo "✓ 生成 auditd 规则文件..."
cat "$INSTALL_DIR/audit.rules.d"/*.rules > /etc/audit/rules.d/sec-auditd.rules
echo "✓ 规则文件已生成: /etc/audit/rules.d/sec-auditd.rules"

echo ""
echo "[4/7] 配置日志轮转..."
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
echo "✓ 日志轮转配置完成"

echo ""
echo "[5/7] 安装告警引擎..."
if [ -z "$SKIP_ALERT_ENGINE" ]; then
    cp -r "$REPO_DIR/alert-engine"/* "$INSTALL_DIR/alert-engine/"
    chmod +x "$INSTALL_DIR/alert-engine/launch-engine.sh"

    # 构建启动命令
    if [ -n "$PYTHON_VERSION" ]; then
        echo "配置使用 Python $PYTHON_VERSION"
        EXEC_CMD="$INSTALL_DIR/alert-engine/launch-engine.sh --python-version $PYTHON_VERSION"
    else
        EXEC_CMD="$INSTALL_DIR/alert-engine/launch-engine.sh"
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
    echo "✓ 告警引擎已安装"
    echo "  配置文件: $INSTALL_DIR/alert-engine/config.yaml"
    echo "  规则目录: $INSTALL_DIR/alert-engine/rules.d/"
else
    echo "⚠ 跳过告警引擎安装（缺少依赖）"
fi

echo ""
echo "[6/7] 安装辅助脚本..."
cp "$REPO_DIR/scripts"/* "$INSTALL_DIR/scripts/" 2>/dev/null || true
chmod +x "$INSTALL_DIR/scripts"/*.sh 2>/dev/null || true
echo "✓ 脚本已安装到 $INSTALL_DIR/scripts/"

echo ""
echo "[7/7] 启动服务..."
# 重新加载 auditd 规则
echo "重新加载 auditd 规则..."
augenrules --load || {
    echo "⚠ augenrules 失败，尝试直接加载规则..."
    auditctl -R /etc/audit/rules.d/sec-auditd.rules
}

# 启动 auditd
systemctl enable auditd
systemctl restart auditd
echo "✓ auditd 服务已启动"

# 检查规则加载情况
RULE_COUNT=$(auditctl -l | wc -l)
echo "✓ 已加载 $RULE_COUNT 条审计规则"

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

if [ -z "$SKIP_ALERT_ENGINE" ]; then
    echo "告警引擎："
    echo "  - 启动引擎: systemctl start sec-auditd-alert"
    echo "  - 开机启动: systemctl enable sec-auditd-alert"
    echo "  - 查看状态: systemctl status sec-auditd-alert"
    echo "  - 查看告警: tail -f $LOG_DIR/alert.log"
    echo ""
    read -p "是否现在启动告警引擎？[y/N] " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        systemctl enable sec-auditd-alert
        systemctl start sec-auditd-alert
        echo "✓ 告警引擎已启动"
    else
        echo "您可以稍后使用以下命令启动："
        echo "  systemctl start sec-auditd-alert"
    fi
fi

echo ""
echo "建议："
echo "  1. 根据实际需求调整规则: $INSTALL_DIR/audit.rules.d/"
echo "  2. 自定义告警规则: $INSTALL_DIR/alert-engine/rules.d/"
echo "  3. 测试规则配置: $INSTALL_DIR/scripts/test-rules.sh"
echo "  4. 配置 filebeat 采集日志（见文档）"
echo ""
