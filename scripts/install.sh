#!/bin/bash
# SEC-AUDITD 安装脚本
# 用于部署 auditd 规则和告警引擎

set -e

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
    # 检查 PyYAML
    if ! python3 -c "import yaml" &> /dev/null; then
        echo "警告：PyYAML 未安装"
        echo "正在安装 PyYAML..."
        pip3 install pyyaml || {
            echo "PyYAML 安装失败，告警引擎将无法使用"
            SKIP_ALERT_ENGINE=1
        }
    else
        echo "✓ PyYAML 已安装"
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
    chmod +x "$INSTALL_DIR/alert-engine/engine.py"

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
ExecStart=/usr/bin/python3 $INSTALL_DIR/alert-engine/engine.py $INSTALL_DIR/alert-engine/config.yaml
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
