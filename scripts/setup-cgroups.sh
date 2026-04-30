#!/bin/bash
# SEC-AUDITD cgroups v2 资源限制配置脚本
# 目标：限制 alert-engine 的资源使用低于 5%

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

# 检查是否为 root
if [ "$EUID" -ne 0 ]; then
    error "请使用 root 权限运行此脚本"
    exit 1
fi

# 检查 cgroups v2 是否挂载
if [ ! -d "/sys/fs/cgroup" ]; then
    error "cgroups v2 未挂载"
    exit 1
fi

info "检测 cgroups 版本..."
if [ -f "/sys/fs/cgroup/cgroup.controllers" ]; then
    info "检测到 cgroups v2"
    CGROUP_VERSION=2
else
    error "仅支持 cgroups v2"
    exit 1
fi

# 获取系统资源信息
info "获取系统资源信息..."
TOTAL_CPUS=$(nproc)
TOTAL_MEM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
TOTAL_MEM_MB=$((TOTAL_MEM_KB / 1024))

info "系统 CPU 核心数: ${TOTAL_CPUS}"
info "系统内存总量: ${TOTAL_MEM_MB} MB"

# 计算 5% 的资源限制
# CPU: 5% 的 CPU 时间
CPU_QUOTA=$((50000))  # 5% of 1 CPU (1000000 us per 1s period)
CPU_PERIOD=1000000    # 1 second in microseconds

# Memory: 5% 的系统内存
MEM_LIMIT_MB=$((TOTAL_MEM_MB * 5 / 100))
MEM_LIMIT_BYTES=$((MEM_LIMIT_MB * 1024 * 1024))

# 确保至少有 64MB 内存
if [ $MEM_LIMIT_MB -lt 64 ]; then
    MEM_LIMIT_MB=64
    MEM_LIMIT_BYTES=$((MEM_LIMIT_MB * 1024 * 1024))
    warn "内存限制调整为最小值: 64 MB"
fi

info "配置资源限制:"
info "  CPU 配额: ${CPU_QUOTA} us / ${CPU_PERIOD} us (~5%)"
info "  内存限制: ${MEM_LIMIT_MB} MB"

# 创建 systemd service drop-in 目录
SYSTEMD_DIR="/etc/systemd/system/sec-auditd-alert.service.d"
mkdir -p "$SYSTEMD_DIR"

# 创建 cgroups 资源限制配置
info "创建 systemd service drop-in 配置..."
cat > "${SYSTEMD_DIR}/resource-limits.conf" <<EOF
# SEC-AUDITD Alert Engine Resource Limits
# 自动生成 - 请勿手动修改
# 生成时间: $(date)

[Service]
# CPU 限制: ~5% 的一个 CPU 核心
CPUQuota=5%

# 内存限制: ${MEM_LIMIT_MB}MB (~5% 系统内存)
MemoryMax=${MEM_LIMIT_BYTES}
MemoryHigh=$((MEM_LIMIT_BYTES * 90 / 100))

# I/O 权重 (10 = 最低优先级, 100 = 默认, 1000 = 最高)
IOWeight=10

# 任务数限制 (防止 fork bomb)
TasksMax=50

# Nice 值 (提高进程优先级，10 = 较低优先级)
Nice=10

# OOM 分数调整 (优先被 OOM killer 杀死)
OOMScoreAdjust=100
EOF

info "资源限制配置已创建: ${SYSTEMD_DIR}/resource-limits.conf"

# 重新加载 systemd 配置
info "重新加载 systemd 配置..."
systemctl daemon-reload

# 显示配置
info "当前配置内容:"
cat "${SYSTEMD_DIR}/resource-limits.conf"

info ""
info "配置完成！"
info ""
info "启用资源限制:"
info "  sudo systemctl restart sec-auditd-alert"
info ""
info "查看资源使用情况:"
info "  systemctl status sec-auditd-alert"
info "  cat /sys/fs/cgroup/system.slice/sec-auditd-alert.service/memory.current"
info "  cat /sys/fs/cgroup/system.slice/sec-auditd-alert.service/cpu.stat"
