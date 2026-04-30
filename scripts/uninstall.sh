#!/bin/bash
# SEC-AUDITD 卸载脚本

set -e

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
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

INSTALL_DIR="/etc/sec-auditd"
LOG_DIR="/var/log/sec-auditd"
KEEP_LOGS=false

# 解析命令行参数
while [[ $# -gt 0 ]]; do
    case $1 in
        --keep-logs|-k)
            KEEP_LOGS=true
            shift
            ;;
        --help|-h)
            echo "用法: $0 [选项]"
            echo ""
            echo "选项:"
            echo "  --keep-logs, -k    保留日志文件"
            echo "  --help, -h         显示此帮助信息"
            echo ""
            exit 0
            ;;
        *)
            error "未知选项: $1"
            echo "使用 --help 查看帮助"
            exit 1
            ;;
    esac
done

echo "======================================"
echo "  SEC-AUDITD 卸载脚本"
echo "======================================"
echo ""

# 检查权限
if [ "$EUID" -ne 0 ]; then
    error "需要 root 权限运行此脚本"
    echo "请使用: sudo $0"
    exit 1
fi

# 询问确认
if [ "$KEEP_LOGS" = false ]; then
    read -p "确认卸载 SEC-AUDITD？这将删除所有配置和日志。[y/N] " -n 1 -r
else
    read -p "确认卸载 SEC-AUDITD？日志文件将保留。[y/N] " -n 1 -r
fi
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    info "取消卸载"
    exit 0
fi

echo ""
info "开始卸载..."

# 步骤 1: 停止服务
info "[1/6] 停止服务..."
if systemctl is-active --quiet sec-auditd-alert 2>/dev/null; then
    systemctl stop sec-auditd-alert
    info "✓ 告警引擎已停止"
fi

if systemctl is-enabled --quiet sec-auditd-alert 2>/dev/null; then
    systemctl disable sec-auditd-alert
    info "✓ 告警引擎开机启动已禁用"
fi

# 步骤 2: 删除 systemd 服务
info "[2/6] 删除 systemd 服务..."
if [ -f "/etc/systemd/system/sec-auditd-alert.service" ]; then
    rm -f /etc/systemd/system/sec-auditd-alert.service
    info "✓ systemd 服务文件已删除"
fi

if [ -d "/etc/systemd/system/sec-auditd-alert.service.d" ]; then
    rm -rf /etc/systemd/system/sec-auditd-alert.service.d
    info "✓ systemd drop-in 配置已删除"
fi

systemctl daemon-reload
info "✓ systemd 配置已重新加载"

# 步骤 3: 移除 auditd 规则
info "[3/6] 移除 auditd 规则..."
if [ -f "/etc/audit/rules.d/sec-auditd.rules" ]; then
    rm -f /etc/audit/rules.d/sec-auditd.rules
    info "✓ auditd 规则文件已删除"
fi

# 重新加载 auditd 规则
augenrules --load 2>/dev/null || {
    warn "auditd 规则重新加载失败"
    info "您可能需要手动重启 auditd: systemctl restart auditd"
}
info "✓ auditd 规则已重新加载"

# 步骤 4: 删除配置文件
info "[4/6] 删除配置文件..."
if [ -d "$INSTALL_DIR" ]; then
    rm -rf "$INSTALL_DIR"
    info "✓ 配置目录已删除: $INSTALL_DIR"
fi

# 步骤 5: 删除日志轮转配置
info "[5/6] 删除日志轮转配置..."
if [ -f "/etc/logrotate.d/sec-auditd" ]; then
    rm -f /etc/logrotate.d/sec-auditd
    info "✓ 日志轮转配置已删除"
fi

# 步骤 6: 处理日志文件
info "[6/6] 处理日志文件..."
if [ "$KEEP_LOGS" = false ]; then
    if [ -d "$LOG_DIR" ]; then
        rm -rf "$LOG_DIR"
        info "✓ 日志目录已删除: $LOG_DIR"
    fi
else
    info "保留日志文件: $LOG_DIR"
fi

echo ""
echo "======================================"
echo "  卸载完成！"
echo "======================================"
echo ""

if [ "$KEEP_LOGS" = true ] && [ -d "$LOG_DIR" ]; then
    echo "保留的日志文件位置："
    echo "  $LOG_DIR"
    echo ""
    echo "如需删除日志："
    echo "  sudo rm -rf $LOG_DIR"
    echo ""
fi

info "SEC-AUDITD 已从系统中移除"
info "auditd 服务仍在运行，如需停止："
echo "  sudo systemctl stop auditd"
echo ""
