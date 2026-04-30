#!/bin/bash
# SEC-AUDITD 性能测试脚本
# 用于评估 alert-engine 在高负载下的资源消耗

set -e

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

highlight() {
    echo -e "${BLUE}$1${NC}"
}

# 检查依赖
check_dependencies() {
    info "检查依赖..."

    local missing=0
    for cmd in python3 systemctl pidstat; do
        if ! command -v $cmd &> /dev/null; then
            error "缺少命令: $cmd"
            missing=1
        fi
    done

    if [ $missing -eq 1 ]; then
        error "请安装缺失的依赖"
        exit 1
    fi
}

# 生成测试数据
generate_test_logs() {
    local count=$1
    local output=$2

    info "生成 ${count} 条测试日志到 ${output}..."

    mkdir -p $(dirname "$output")

    # 生成各种类型的 audit 事件
    for i in $(seq 1 $count); do
        local timestamp=$(echo "$(date +%s).${i}" | bc)
        local serial=$i

        # 随机生成不同类型的事件
        case $((i % 4)) in
            0)
                # 进程执行事件
                echo "type=EXECVE msg=audit(${timestamp}:${serial}): argc=3 a0=\"/bin/ls\" a1=\"-la\" a2=\"/tmp\" key=\"process_exec\"" >> "$output"
                ;;
            1)
                # 网络连接事件
                echo "type=SYSCALL msg=audit(${timestamp}:${serial}): arch=c000003e syscall=42 success=yes exit=0 a0=3 a1=7fff12345678 a2=10 pid=12345 uid=1000 gid=1000 euid=1000 exe=\"/usr/bin/curl\" key=\"network_connect\"" >> "$output"
                ;;
            2)
                # 文件修改事件
                echo "type=SYSCALL msg=audit(${timestamp}:${serial}): arch=c000003e syscall=2 success=yes exit=3 a0=7fff12345678 a1=241 a2=1b6 pid=12345 uid=0 gid=0 euid=0 exe=\"/usr/bin/vim\" key=\"passwd_changes\"" >> "$output"
                ;;
            3)
                # 临时目录执行
                echo "type=EXECVE msg=audit(${timestamp}:${serial}): argc=1 a0=\"/tmp/suspicious_script\" key=\"tmp_exec\"" >> "$output"
                ;;
        esac
    done

    info "测试日志生成完成: $(wc -l < "$output") 行"
}

# 监控进程资源使用
monitor_process() {
    local pid=$1
    local duration=$2
    local output_file=$3

    info "监控进程 PID ${pid} 持续 ${duration} 秒..."

    # 记录开始时间
    local start_time=$(date +%s)

    # 记录系统信息
    echo "# 系统信息" > "$output_file"
    echo "CPU 核心数: $(nproc)" >> "$output_file"
    echo "内存总量: $(free -h | awk '/^Mem:/ {print $2}')" >> "$output_file"
    echo "" >> "$output_file"

    # 持续监控
    echo "# 资源使用监控数据" >> "$output_file"
    echo "timestamp,cpu_percent,mem_rss_mb,mem_vms_mb,threads,fds" >> "$output_file"

    while [ $(($(date +%s) - start_time)) -lt $duration ]; do
        if [ ! -d "/proc/$pid" ]; then
            warn "进程已退出"
            break
        fi

        # 获取 CPU 使用率
        local cpu=$(ps -p $pid -o %cpu= | tr -d ' ')

        # 获取内存使用 (RSS 和 VMS)
        local mem_rss=$(ps -p $pid -o rss= | tr -d ' ')
        local mem_vms=$(ps -p $pid -o vsz= | tr -d ' ')
        local mem_rss_mb=$(echo "scale=2; $mem_rss / 1024" | bc)
        local mem_vms_mb=$(echo "scale=2; $mem_vms / 1024" | bc)

        # 获取线程数
        local threads=$(ps -p $pid -o nlwp= | tr -d ' ')

        # 获取文件描述符数
        local fds=$(ls -1 /proc/$pid/fd 2>/dev/null | wc -l)

        # 记录数据
        echo "$(date +%s),$cpu,$mem_rss_mb,$mem_vms_mb,$threads,$fds" >> "$output_file"

        sleep 1
    done

    info "监控数据已保存到: $output_file"
}

# 分析监控数据
analyze_results() {
    local data_file=$1

    info "分析性能数据..."

    # 提取数据
    local cpu_avg=$(awk -F',' 'NR>2 && $2 != "" {sum+=$2; count++} END {if(count>0) print sum/count; else print 0}' "$data_file")
    local cpu_max=$(awk -F',' 'NR>2 && $2 != "" {if($2>max) max=$2} END {print max+0}' "$data_file")

    local mem_avg=$(awk -F',' 'NR>2 && $3 != "" {sum+=$3; count++} END {if(count>0) print sum/count; else print 0}' "$data_file")
    local mem_max=$(awk -F',' 'NR>2 && $3 != "" {if($3>max) max=$3} END {print max+0}' "$data_file")

    local threads_avg=$(awk -F',' 'NR>2 && $5 != "" {sum+=$5; count++} END {if(count>0) print sum/count; else print 0}' "$data_file")
    local fds_avg=$(awk -F',' 'NR>2 && $6 != "" {sum+=$6; count++} END {if(count>0) print sum/count; else print 0}' "$data_file")

    # 获取系统总资源
    local total_cpus=$(nproc)
    local total_mem_mb=$(free -m | awk '/^Mem:/ {print $2}')

    # 计算百分比
    local cpu_percent=$(echo "scale=2; $cpu_avg" | bc)
    local mem_percent=$(echo "scale=2; $mem_avg * 100 / $total_mem_mb" | bc)

    # 输出结果
    echo ""
    highlight "=========================================="
    highlight "          性能测试结果"
    highlight "=========================================="
    echo ""

    echo "系统资源:"
    echo "  CPU 核心数: $total_cpus"
    echo "  内存总量: ${total_mem_mb} MB"
    echo ""

    echo "Alert Engine 资源使用:"
    echo "  CPU 使用率:"
    echo "    平均: ${cpu_percent}%"
    echo "    峰值: ${cpu_max}%"
    echo ""

    echo "  内存使用:"
    echo "    平均: ${mem_avg} MB (${mem_percent}% 系统内存)"
    echo "    峰值: ${mem_max} MB"
    echo ""

    echo "  其他指标:"
    echo "    平均线程数: ${threads_avg}"
    echo "    平均文件描述符: ${fds_avg}"
    echo ""

    # 评估是否满足 5% 目标
    local target_met=1

    highlight "目标评估 (< 5%):"

    # CPU 评估
    if (( $(echo "$cpu_avg < 5.0" | bc -l) )); then
        echo -e "  CPU: ${GREEN}✓ 通过${NC} (${cpu_percent}% < 5%)"
    else
        echo -e "  CPU: ${RED}✗ 未通过${NC} (${cpu_percent}% >= 5%)"
        target_met=0
    fi

    # 内存评估
    if (( $(echo "$mem_percent < 5.0" | bc -l) )); then
        echo -e "  内存: ${GREEN}✓ 通过${NC} (${mem_percent}% < 5%)"
    else
        echo -e "  内存: ${RED}✗ 未通过${NC} (${mem_percent}% >= 5%)"
        target_met=0
    fi

    echo ""

    if [ $target_met -eq 1 ]; then
        highlight "总体评估: ✓ 满足资源限制目标 (< 5%)"
    else
        warn "总体评估: ✗ 未满足资源限制目标"
    fi

    echo ""
    highlight "=========================================="

    return $target_met
}

# 主函数
main() {
    local test_duration=${1:-30}  # 默认测试 30 秒
    local log_count=${2:-10000}   # 默认生成 10000 条日志

    info "SEC-AUDITD 性能测试"
    info "测试持续时间: ${test_duration} 秒"
    info "生成日志数量: ${log_count} 条"
    echo ""

    # 创建临时目录
    local temp_dir=$(mktemp -d)
    local test_log="${temp_dir}/test-audit.log"
    local monitor_data="${temp_dir}/monitor.csv"
    local config_file="/home/runner/work/sec-auditd/sec-auditd/alert-engine/config.yaml"

    trap "rm -rf $temp_dir" EXIT

    check_dependencies

    # 生成测试数据
    generate_test_logs $log_count "$test_log"

    # 创建临时配置
    local temp_config="${temp_dir}/config.yaml"
    sed "s|file: /var/log/audit/audit.log|file: ${test_log}|g" "$config_file" > "$temp_config"
    sed -i "s|path: /var/log/sec-auditd/alert.log|path: ${temp_dir}/alert.log|g" "$temp_config"

    info "启动 alert-engine..."
    python3 /home/runner/work/sec-auditd/sec-auditd/alert-engine/engine.py "$temp_config" &
    local engine_pid=$!

    # 等待引擎启动
    sleep 2

    if [ ! -d "/proc/$engine_pid" ]; then
        error "引擎启动失败"
        exit 1
    fi

    info "引擎 PID: $engine_pid"

    # 开始监控
    monitor_process $engine_pid $test_duration "$monitor_data"

    # 停止引擎
    info "停止 alert-engine..."
    kill $engine_pid 2>/dev/null || true
    wait $engine_pid 2>/dev/null || true

    # 分析结果
    analyze_results "$monitor_data"

    local result=$?

    info "详细监控数据: $monitor_data"
    info "测试日志: $test_log"

    return $result
}

# 显示用法
show_usage() {
    echo "用法: $0 [测试时长(秒)] [日志数量]"
    echo ""
    echo "示例:"
    echo "  $0           # 默认: 30秒, 10000条日志"
    echo "  $0 60 20000  # 60秒, 20000条日志"
    echo ""
}

# 解析参数
if [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
    show_usage
    exit 0
fi

main "$@"
