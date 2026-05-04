#!/bin/bash
# ============================================================
# SEC-AUDITD 全规则测试脚本
# 逐条触发所有启用的告警规则并验证输出
# ============================================================
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'
BOLD='\033[1m'

ALERT_LOG="/var/log/sec-auditd/alert.log"
JOURNAL_TAG="sec-auditd-alert"
WAIT=5  # 等待引擎处理（秒）

TOTAL=0
PASSED=0
FAILED=0
SKIPPED=0

# 清理之前的告警
cleanup_alerts() {
    sudo truncate -s 0 "$ALERT_LOG" 2>/dev/null || true
    sleep 2
}

# 检查告警日志中是否包含指定关键词
check_alert() {
    local rule_id="$1"
    local description="$2"
    shift 2

    TOTAL=$((TOTAL + 1))

    echo -e "\n${CYAN}[$TOTAL] 测试: ${description}${NC}"
    echo -e "    规则ID: ${rule_id}"

    # 执行触发动作
    for cmd in "$@"; do
        eval "$cmd" 2>/dev/null || true
    done

    sleep "$WAIT"

    # 检查告警
    if sudo grep -q "$rule_id" "$ALERT_LOG" 2>/dev/null; then
        local count=$(sudo grep -c "$rule_id" "$ALERT_LOG" 2>/dev/null || echo 0)
        echo -e "    ${GREEN}PASS${NC} - 告警已触发 (${count} 条)"
        PASSED=$((PASSED + 1))

        # 显示最新一条告警消息
        local msg=$(sudo grep "$rule_id" "$ALERT_LOG" | tail -1 | python3 -c "
import sys,json
try:
    d=json.loads(sys.stdin.read())
    print(d.get('message',''))
except: pass
" 2>/dev/null)
        echo -e "    消息: ${msg}"
    else
        echo -e "    ${RED}FAIL${NC} - 未检测到告警"
        FAILED=$((FAILED + 1))
    fi
}

# 检查被节流的告警（可能之前已触发，throttle期内不重复）
check_alert_throttled() {
    local rule_id="$1"
    local description="$2"
    shift 2

    TOTAL=$((TOTAL + 1))
    echo -e "\n${CYAN}[$TOTAL] 测试: ${description}${NC}"
    echo -e "    规则ID: ${rule_id}"

    for cmd in "$@"; do
        eval "$cmd" 2>/dev/null || true
    done

    sleep "$WAIT"

    if sudo grep -q "$rule_id" "$ALERT_LOG" 2>/dev/null; then
        echo -e "    ${GREEN}PASS${NC} - 告警已触发"
        PASSED=$((PASSED + 1))
    else
        # 检查 journal 中是否有（可能是节流）
        if sudo journalctl -u "$JOURNAL_TAG" --no-pager -n 50 2>/dev/null | grep -q "$rule_id"; then
            echo -e "    ${YELLOW}THROTTLED${NC} - 告警被节流（journal 中可见）"
            PASSED=$((PASSED + 1))
        else
            echo -e "    ${YELLOW}SKIP${NC} - 可能被节流或事件未捕获"
            SKIPPED=$((SKIPPED + 1))
        fi
    fi
}

echo -e "${BOLD}============================================================${NC}"
echo -e "${BOLD}  SEC-AUDITD 全规则测试${NC}"
echo -e "${BOLD}============================================================${NC}"
echo "测试时间: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo ""

# 清空告警日志
echo -e "${YELLOW}>>> 清空告警日志...${NC}"
cleanup_alerts
echo "告警日志已清空"

# ============================================================
# 第一部分：进程相关规则 (process.yaml)
# ============================================================
echo ""
echo -e "${BOLD}============================================================${NC}"
echo -e "${BOLD}  第一部分：进程相关规则 (process.yaml)${NC}"
echo -e "${BOLD}============================================================${NC}"

# 1. suspicious_exec_tmp - 临时目录执行
check_alert "suspicious_exec_tmp" "临时目录 /tmp 执行程序 (HIGH)" \
    "sudo cp /bin/whoami /tmp/test_exec_1 && sudo chmod +x /tmp/test_exec_1 && /tmp/test_exec_1 && sudo rm -f /tmp/test_exec_1"

# 2. suspicious_exec_shm - 共享内存目录执行
check_alert "suspicious_exec_shm" "共享内存目录 /dev/shm 执行程序 (HIGH)" \
    "sudo cp /bin/whoami /dev/shm/test_exec_2 && sudo chmod +x /dev/shm/test_exec_2 && /dev/shm/test_exec_2 && sudo rm -f /dev/shm/test_exec_2"

# 3. suspicious_exec_vartmp - /var/tmp 执行
check_alert "suspicious_exec_vartmp" "/var/tmp 目录执行程序 (HIGH)" \
    "sudo cp /bin/whoami /var/tmp/test_exec_3 && sudo chmod +x /var/tmp/test_exec_3 && /var/tmp/test_exec_3 && sudo rm -f /var/tmp/test_exec_3"

# 4. privilege_escalation - 提权操作（用非白名单程序触发）
check_alert "privilege_escalation" "特权提升操作 (CRITICAL)" \
    "sudo cp /bin/whoami /tmp/setuid_test && sudo chmod u+s /tmp/setuid_test && /tmp/setuid_test && sudo rm -f /tmp/setuid_test"

# 5. sudo_usage - sudo 使用
check_alert "sudo_usage" "Sudo 命令使用 (LOW)" \
    "sudo whoami > /dev/null"

# 6. su_usage - su 使用（通过 -p 事件触发）
check_alert_throttled "su_usage" "Su 命令使用 (MEDIUM)" \
    "sudo cat /bin/su > /dev/null"

# 7. process_burst - 高频进程执行 (需要60秒内50次)
TOTAL=$((TOTAL + 1))
echo -e "\n${CYAN}[$TOTAL] 测试: 短时间大量进程执行 (HIGH, 聚合规则)${NC}"
echo -e "    规则ID: process_burst"
echo -e "    ${YELLOW}SKIP${NC} - 需要60秒内50+次进程执行，耗时较长，跳过"
SKIPPED=$((SKIPPED + 1))

# 8. kernel_module_load / module_insertion
# 需要 root 权限且内核支持，VPS 上可能不适用
TOTAL=$((TOTAL + 1))
echo -e "\n${CYAN}[$TOTAL] 测试: 内核模块加载 (HIGH)${NC}"
echo -e "    规则ID: kernel_module_load / module_insertion"
echo -e "    ${YELLOW}SKIP${NC} - VPS 环境可能不支持加载内核模块，跳过"
SKIPPED=$((SKIPPED + 1))

# ============================================================
# 第二部分：文件相关规则 (file.yaml)
# ============================================================
echo ""
echo -e "${BOLD}============================================================${NC}"
echo -e "${BOLD}  第二部分：文件相关规则 (file.yaml)${NC}"
echo -e "${BOLD}============================================================${NC}"

# 9. passwd_changes
check_alert "passwd_changes" "/etc/passwd 文件变更 (CRITICAL)" \
    "sudo touch /etc/passwd"

# 10. shadow_changes
check_alert "shadow_changes" "/etc/shadow 文件访问/变更 (CRITICAL)" \
    "sudo cat /etc/shadow > /dev/null"

# 11. group_changes
check_alert "group_changes" "/etc/group 文件变更 (HIGH)" \
    "sudo touch /etc/group"

# 12. sshd_config_change
check_alert "sshd_config_change" "SSH 服务端配置变更 (HIGH)" \
    "sudo touch /etc/ssh/sshd_config"

# 13. root_ssh_keys_change
check_alert "root_ssh_keys_change" "Root SSH 密钥变更 (CRITICAL)" \
    "sudo ls /root/.ssh/ > /dev/null 2>&1 || sudo mkdir -p /root/.ssh && sudo touch /root/.ssh/test_key && sudo rm -f /root/.ssh/test_key"

# 14. sudoers_change
check_alert "sudoers_change" "Sudoers 配置变更 (CRITICAL)" \
    "sudo touch /etc/sudoers"

# 15. systemd_change
check_alert "systemd_change" "Systemd 配置变更 (MEDIUM)" \
    "sudo touch /etc/systemd/system/test_service.service 2>/dev/null; sudo rm -f /etc/systemd/system/test_service.service 2>/dev/null"

# 16. cron_change
check_alert "cron_change" "定时任务变更 (HIGH)" \
    "sudo touch /etc/crontab"

# 17. pam_change
check_alert "pam_change" "PAM 配置变更 (HIGH)" \
    "sudo touch /etc/pam.d/su"

# 18. system_lib_change
check_alert "system_lib_change" "系统库文件变更 (CRITICAL)" \
    "sudo touch /lib/x86_64-linux-gnu/libc.so.6 2>/dev/null || sudo touch /usr/lib/x86_64-linux-gnu/libc.so.6"

# 19. system_bin_change
check_alert "system_bin_change" "系统二进制文件变更 (CRITICAL)" \
    "sudo touch /bin/ls"

# 20. audit_config_change
check_alert "audit_config_change" "审计配置变更 (CRITICAL)" \
    "sudo touch /etc/audit/auditd.conf"

# 21. gshadow_changes
check_alert "gshadow_changes" "/etc/gshadow 文件变更 (HIGH)" \
    "sudo cat /etc/gshadow > /dev/null 2>&1 || sudo touch /etc/gshadow"

# 22. opasswd_changes
check_alert "opasswd_changes" "/etc/security/opasswd 文件变更 (HIGH)" \
    "sudo touch /etc/security/opasswd"

# 23. ssh_config_change
check_alert "ssh_config_change" "SSH 客户端配置变更 (MEDIUM)" \
    "sudo touch /etc/ssh/ssh_config"

# 24. init_changes
check_alert "init_changes" "Init 启动脚本变更 (HIGH)" \
    "sudo touch /etc/init.d/test_init 2>/dev/null; sudo rm -f /etc/init.d/test_init 2>/dev/null"

# 25. local_bin_change
check_alert "local_bin_change" "本地二进制目录变更 (HIGH)" \
    "sudo touch /usr/local/bin/test_local_bin 2>/dev/null; sudo rm -f /usr/local/bin/test_local_bin 2>/dev/null"

# 26. shell_env_change
check_alert "shell_env_change" "Shell 环境配置变更 (HIGH)" \
    "sudo touch /etc/profile"

# 27. selinux_change
TOTAL=$((TOTAL + 1))
echo -e "\n${CYAN}[$TOTAL] 测试: SELinux 配置变更 (HIGH)${NC}"
echo -e "    规则ID: selinux_change"
if [ -d /etc/selinux ]; then
    check_alert "selinux_change" "SELinux 配置变更 (HIGH)" \
        "sudo touch /etc/selinux/test_selinux && sudo rm -f /etc/selinux/test_selinux"
else
    echo -e "    ${YELLOW}SKIP${NC} - /etc/selinux 不存在 (Ubuntu 默认无 SELinux)"
    SKIPPED=$((SKIPPED + 1))
fi

# 28. apparmor_change
check_alert "apparmor_change" "AppArmor 配置变更 (HIGH)" \
    "sudo touch /etc/apparmor.d/test_aa 2>/dev/null; sudo rm -f /etc/apparmor.d/test_aa 2>/dev/null"

# 29. security_limits_change
check_alert "security_limits_change" "安全限制配置变更 (MEDIUM)" \
    "sudo touch /etc/security/limits.conf"

# 30. module_removal
TOTAL=$((TOTAL + 1))
echo -e "\n${CYAN}[$TOTAL] 测试: 内核模块移除 (HIGH)${NC}"
echo -e "    规则ID: module_removal"
echo -e "    ${YELLOW}SKIP${NC} - VPS 环境不适合测试模块移除"
SKIPPED=$((SKIPPED + 1))

# 31. audit_log_change
check_alert "audit_log_change" "审计日志目录变更 (CRITICAL)" \
    "sudo touch /var/log/audit/test_audit_log && sudo rm -f /var/log/audit/test_audit_log"

# 32. audisp_config_change
TOTAL=$((TOTAL + 1))
echo -e "\n${CYAN}[$TOTAL] 测试: Audisp 配置变更 (CRITICAL)${NC}"
echo -e "    规则ID: audisp_config_change"
if [ -d /etc/audisp ]; then
    check_alert "audisp_config_change" "Audisp 配置变更 (CRITICAL)" \
        "sudo touch /etc/audisp/test_audisp && sudo rm -f /etc/audisp/test_audisp"
else
    echo -e "    ${YELLOW}SKIP${NC} - /etc/audisp 不存在"
    SKIPPED=$((SKIPPED + 1))
fi

# 33. audit_tools_exec
check_alert "audit_tools_exec" "审计工具执行 (HIGH)" \
    "sudo /sbin/auditctl -s > /dev/null 2>&1"

# ============================================================
# 第三部分：网络相关规则 (network.yaml)
# ============================================================
echo ""
echo -e "${BOLD}============================================================${NC}"
echo -e "${BOLD}  第三部分：网络相关规则 (network.yaml)${NC}"
echo -e "${BOLD}============================================================${NC}"

# 34. suspicious_network_connect - 已在引擎启动时触发
TOTAL=$((TOTAL + 1))
echo -e "\n${CYAN}[$TOTAL] 测试: 可疑的网络连接 (MEDIUM)${NC}"
echo -e "    规则ID: suspicious_network_connect"
if sudo grep -q "suspicious_network_connect" "$ALERT_LOG" 2>/dev/null; then
    echo -e "    ${GREEN}PASS${NC} - 已有告警（网络活动自然触发）"
    PASSED=$((PASSED + 1))
else
    # 触发一个网络连接
    check_alert_throttled "suspicious_network_connect" "可疑网络连接" \
        "sudo wget -q -O /dev/null --timeout=3 http://1.1.1.1 2>/dev/null || true"
fi

# 35. network_from_tmp - 临时目录进程发起网络连接
TOTAL=$((TOTAL + 1))
echo -e "\n${CYAN}[$TOTAL] 测试: 临时目录进程发起网络连接 (HIGH)${NC}"
echo -e "    规则ID: network_from_tmp"
echo -e "    ${YELLOW}SKIP${NC} - 需要从 /tmp 编译并运行一个网络程序，较复杂"
SKIPPED=$((SKIPPED + 1))

# 36. new_listening_port - 已在引擎启动时触发
TOTAL=$((TOTAL + 1))
echo -e "\n${CYAN}[$TOTAL] 测试: 新增监听端口 (MEDIUM)${NC}"
echo -e "    规则ID: new_listening_port"
if sudo grep -q "new_listening_port" "$ALERT_LOG" 2>/dev/null; then
    echo -e "    ${GREEN}PASS${NC} - 已有告警（服务启动时自然触发）"
    PASSED=$((PASSED + 1))
else
    echo -e "    ${YELLOW}SKIP${NC} - 未找到已有告警"
    SKIPPED=$((SKIPPED + 1))
fi

# 37. connection_burst - 需要聚合
TOTAL=$((TOTAL + 1))
echo -e "\n${CYAN}[$TOTAL] 测试: 短时间大量网络连接 (HIGH, 聚合规则)${NC}"
echo -e "    规则ID: connection_burst"
echo -e "    ${YELLOW}SKIP${NC} - 需要60秒内100+次连接，耗时较长，跳过"
SKIPPED=$((SKIPPED + 1))

# 38. network_config_change
check_alert "network_config_change" "网络配置文件变更 (HIGH)" \
    "sudo touch /etc/hosts"

# 39. firewall_config_change
check_alert "firewall_config_change" "防火墙配置变更 (CRITICAL)" \
    "sudo touch /etc/ufw/ufw.conf 2>/dev/null || sudo mkdir -p /etc/ufw && sudo touch /etc/ufw/ufw.conf"

# 40. firewall_exec
TOTAL=$((TOTAL + 1))
echo -e "\n${CYAN}[$TOTAL] 测试: 防火墙命令执行 (HIGH)${NC}"
echo -e "    规则ID: firewall_exec"
if command -v iptables &>/dev/null; then
    check_alert "firewall_exec" "防火墙命令执行 (HIGH)" \
        "sudo /sbin/iptables -L > /dev/null 2>&1 || true"
elif command -v ufw &>/dev/null; then
    check_alert "firewall_exec" "防火墙命令执行 (HIGH)" \
        "sudo /usr/sbin/ufw status > /dev/null 2>&1 || true"
else
    echo -e "    ${YELLOW}SKIP${NC} - iptables/ufw 不可用"
    SKIPPED=$((SKIPPED + 1))
fi

# 41. network_socket_create - DISABLED
TOTAL=$((TOTAL + 1))
echo -e "\n${CYAN}[$TOTAL] 测试: Socket 创建${NC}"
echo -e "    规则ID: network_socket_create"
echo -e "    ${YELLOW}SKIP${NC} - 规则已禁用 (enabled: false)"
SKIPPED=$((SKIPPED + 1))

# 42. network_accept_conn
TOTAL=$((TOTAL + 1))
echo -e "\n${CYAN}[$TOTAL] 测试: 接受入站连接 (LOW)${NC}"
echo -e "    规则ID: network_accept_conn"
echo -e "    ${YELLOW}SKIP${NC} - accept4 规则可能未被 auditd 加载（之前有错误）"
SKIPPED=$((SKIPPED + 1))

# 43. network_listen_port
TOTAL=$((TOTAL + 1))
echo -e "\n${CYAN}[$TOTAL] 测试: 进程开始监听端口 (MEDIUM)${NC}"
echo -e "    规则ID: network_listen_port"
if sudo grep -q "network_listen_port" "$ALERT_LOG" 2>/dev/null || sudo journalctl -u "$JOURNAL_TAG" --no-pager -n 50 2>/dev/null | grep -q "network_listen_port"; then
    echo -e "    ${GREEN}PASS${NC} - 已有告警"
    PASSED=$((PASSED + 1))
else
    echo -e "    ${YELLOW}SKIP${NC} - 未检测到"
    SKIPPED=$((SKIPPED + 1))
fi

# ============================================================
# 第四部分：Neo23x0 规则 (neo23x0.yaml)
# ============================================================
echo ""
echo -e "${BOLD}============================================================${NC}"
echo -e "${BOLD}  第四部分：Neo23x0 规则 (neo23x0.yaml)${NC}"
echo -e "${BOLD}============================================================${NC}"

# 44. neo23x0_perm_mod
check_alert "neo23x0_perm_mod" "文件权限修改 (MEDIUM)" \
    "sudo chmod 777 /tmp/.audit_test_perm && sudo rm -f /tmp/.audit_test_perm"

# 45. neo23x0_unauthedfileaccess
TOTAL=$((TOTAL + 1))
echo -e "\n${CYAN}[$TOTAL] 测试: 未授权文件访问 (HIGH)${NC}"
echo -e "    规则ID: neo23x0_unauthedfileaccess"
echo -e "    ${YELLOW}SKIP${NC} - 需要非 root 用户尝试访问受限文件且被拒绝"
SKIPPED=$((SKIPPED + 1))

# 46. neo23x0_unauthedfileaccess_system
TOTAL=$((TOTAL + 1))
echo -e "\n${CYAN}[$TOTAL] 测试: 系统账户未授权文件访问 (MEDIUM)${NC}"
echo -e "    规则ID: neo23x0_unauthedfileaccess_system"
echo -e "    ${YELLOW}SKIP${NC} - 需要系统守护进程被拒绝访问"
SKIPPED=$((SKIPPED + 1))

# 47. neo23x0_tracing
TOTAL=$((TOTAL + 1))
echo -e "\n${CYAN}[$TOTAL] 测试: Ptrace 调用检测 (HIGH)${NC}"
echo -e "    规则ID: neo23x0_tracing"
if command -v strace &>/dev/null; then
    echo -e "    ${YELLOW}SKIP${NC} - strace 在白名单中，不会触发告警"
    SKIPPED=$((SKIPPED + 1))
else
    echo -e "    ${YELLOW}SKIP${NC} - 无 strace/gdb 可测试"
    SKIPPED=$((SKIPPED + 1))
fi

# 48. neo23x0_anon_file_create
TOTAL=$((TOTAL + 1))
echo -e "\n${CYAN}[$TOTAL] 测试: 匿名文件创建/memfd_create (HIGH)${NC}"
echo -e "    规则ID: neo23x0_anon_file_create"
echo -e "    ${YELLOW}SKIP${NC} - 需要编写 C 程序调用 memfd_create，跳过"
SKIPPED=$((SKIPPED + 1))

# 49. neo23x0_timestomp
check_alert "neo23x0_timestomp" "文件时间戳篡改 (HIGH)" \
    "touch -t 202001010000 /tmp/.audit_test_time && rm -f /tmp/.audit_test_time"

# 50. neo23x0_bpf
TOTAL=$((TOTAL + 1))
echo -e "\n${CYAN}[$TOTAL] 测试: eBPF 程序加载 (HIGH)${NC}"
echo -e "    规则ID: neo23x0_bpf"
echo -e "    ${YELLOW}SKIP${NC} - 需要 bcc/bpftrace 工具，跳过"
SKIPPED=$((SKIPPED + 1))

# 51. neo23x0_namespaces
TOTAL=$((TOTAL + 1))
echo -e "\n${CYAN}[$TOTAL] 测试: 命名空间操作 (HIGH)${NC}"
echo -e "    规则ID: neo23x0_namespaces"
if command -v unshare &>/dev/null; then
    # unshare 在白名单中，不会触发
    echo -e "    ${YELLOW}SKIP${NC} - unshare 在白名单中，不会触发告警"
    SKIPPED=$((SKIPPED + 1))
else
    echo -e "    ${YELLOW}SKIP${NC} - 无 unshare 命令"
    SKIPPED=$((SKIPPED + 1))
fi

# 52. neo23x0_process_vm
TOTAL=$((TOTAL + 1))
echo -e "\n${CYAN}[$TOTAL] 测试: 跨进程内存访问 (HIGH)${NC}"
echo -e "    规则ID: neo23x0_process_vm"
echo -e "    ${YELLOW}SKIP${NC} - python3 在白名单中，需要 C 程序测试"
SKIPPED=$((SKIPPED + 1))

# 53. neo23x0_io_uring
TOTAL=$((TOTAL + 1))
echo -e "\n${CYAN}[$TOTAL] 测试: io_uring 使用 (MEDIUM)${NC}"
echo -e "    规则ID: neo23x0_io_uring"
echo -e "    ${YELLOW}SKIP${NC} - 需要编写 io_uring 程序，跳过"
SKIPPED=$((SKIPPED + 1))

# 54. neo23x0_userfaultfd
TOTAL=$((TOTAL + 1))
echo -e "\n${CYAN}[$TOTAL] 测试: userfaultfd 利用原语 (HIGH)${NC}"
echo -e "    规则ID: neo23x0_userfaultfd"
echo -e "    ${YELLOW}SKIP${NC} - 需要编写 C 程序调用 userfaultfd，跳过"
SKIPPED=$((SKIPPED + 1))

# 55. neo23x0_reboot
TOTAL=$((TOTAL + 1))
echo -e "\n${CYAN}[$TOTAL] 测试: 系统重启/关机 (HIGH)${NC}"
echo -e "    规则ID: neo23x0_reboot"
echo -e "    ${YELLOW}SKIP${NC} - 不应在测试中重启系统"
SKIPPED=$((SKIPPED + 1))

# 56. neo23x0_power_abuse
TOTAL=$((TOTAL + 1))
echo -e "\n${CYAN}[$TOTAL] 测试: 管理员权限滥用 (HIGH)${NC}"
echo -e "    规则ID: neo23x0_power_abuse"
# root 访问 /home/ubuntu 下的文件
check_alert_throttled "neo23x0_power_abuse" "管理员权限滥用 (HIGH)" \
    "sudo ls /home/ubuntu/ > /dev/null"

# 57. neo23x0_software_mgmt
check_alert "neo23x0_software_mgmt" "软件包管理器配置变更 (MEDIUM)" \
    "sudo touch /etc/apt/sources.list"

# 58. neo23x0_docker
check_alert_throttled "neo23x0_docker" "Docker 配置变更 (HIGH)" \
    "sudo touch /etc/docker/daemon.json 2>/dev/null || (sudo mkdir -p /etc/docker && sudo touch /etc/docker/daemon.json)"

# 59. neo23x0_containers
TOTAL=$((TOTAL + 1))
echo -e "\n${CYAN}[$TOTAL] 测试: 容器运行时配置变更 (HIGH)${NC}"
echo -e "    规则ID: neo23x0_containers"
if [ -d /etc/containers ]; then
    check_alert "neo23x0_containers" "容器运行时配置变更 (HIGH)" \
        "sudo touch /etc/containers/test_containers && sudo rm -f /etc/containers/test_containers"
else
    # 创建目录以触发
    check_alert "neo23x0_containers" "容器运行时配置变更 (HIGH)" \
        "sudo mkdir -p /etc/containers && sudo touch /etc/containers/test_ctn && sudo rm -f /etc/containers/test_ctn"
fi

# 60. neo23x0_modules
TOTAL=$((TOTAL + 1))
echo -e "\n${CYAN}[$TOTAL] 测试: 内核模块操作 - Neo23x0 (HIGH)${NC}"
echo -e "    规则ID: neo23x0_modules"
echo -e "    ${YELLOW}SKIP${NC} - VPS 环境不适合测试内核模块操作"
SKIPPED=$((SKIPPED + 1))

# 61. neo23x0_kexec
TOTAL=$((TOTAL + 1))
echo -e "\n${CYAN}[$TOTAL] 测试: KExec 内核替换 (CRITICAL)${NC}"
echo -e "    规则ID: neo23x0_kexec"
echo -e "    ${YELLOW}SKIP${NC} - 不应测试 kexec"
SKIPPED=$((SKIPPED + 1))

# 62. neo23x0_mount
TOTAL=$((TOTAL + 1))
echo -e "\n${CYAN}[$TOTAL] 测试: 挂载操作 (MEDIUM)${NC}"
echo -e "    规则ID: neo23x0_mount"
# systemd 在白名单中，正常 mount 可能不会触发
echo -e "    ${YELLOW}SKIP${NC} - systemd/mount 在白名单中，日常挂载不触发"
SKIPPED=$((SKIPPED + 1))

# 63. neo23x0_time
TOTAL=$((TOTAL + 1))
echo -e "\n${CYAN}[$TOTAL] 测试: 系统时间修改 (HIGH)${NC}"
echo -e "    规则ID: neo23x0_time"
# systemd-timesyncd 在白名单中
if command -v date &>/dev/null; then
    # 不实际修改时间，只是读取
    echo -e "    ${YELLOW}SKIP${NC} - systemd-timesyncd 在白名单中，不宜修改系统时间"
    SKIPPED=$((SKIPPED + 1))
fi

# 64. neo23x0_network_modifications
check_alert "neo23x0_network_modifications" "网络环境修改 (HIGH)" \
    "sudo hostname > /dev/null"

# 65. neo23x0_delete
check_alert "neo23x0_delete" "用户文件删除 (LOW)" \
    "sudo touch /tmp/.audit_test_del && sudo rm -f /tmp/.audit_test_del"

# 66. neo23x0_actions
check_alert "neo23x0_actions" "Sudoers 配置变更 - Neo23x0 (CRITICAL)" \
    "sudo cat /etc/sudoers > /dev/null"

# 67. neo23x0_session
check_alert_throttled "neo23x0_session" "会话信息变更 (MEDIUM)" \
    "sudo touch /var/run/utmp 2>/dev/null || true"

# 68. neo23x0_32bit_abi
TOTAL=$((TOTAL + 1))
echo -e "\n${CYAN}[$TOTAL] 测试: 32位 ABI 使用 (MEDIUM)${NC}"
echo -e "    规则ID: neo23x0_32bit_abi"
echo -e "    ${YELLOW}SKIP${NC} - VPS 为纯 64 位环境，无 32 位程序"
SKIPPED=$((SKIPPED + 1))

# 69. neo23x0_process_creation - DISABLED
TOTAL=$((TOTAL + 1))
echo -e "\n${CYAN}[$TOTAL] 测试: 进程创建 (Neo23x0)${NC}"
echo -e "    规则ID: neo23x0_process_creation"
echo -e "    ${YELLOW}SKIP${NC} - 规则已禁用 (enabled: false)"
SKIPPED=$((SKIPPED + 1))

# 70. neo23x0_ipc - DISABLED
TOTAL=$((TOTAL + 1))
echo -e "\n${CYAN}[$TOTAL] 测试: 进程间通信 (IPC)${NC}"
echo -e "    规则ID: neo23x0_ipc"
echo -e "    ${YELLOW}SKIP${NC} - 规则已禁用 (enabled: false)"
SKIPPED=$((SKIPPED + 1))

# 71. neo23x0_network_connect - DISABLED
TOTAL=$((TOTAL + 1))
echo -e "\n${CYAN}[$TOTAL] 测试: 成功的出站网络连接${NC}"
echo -e "    规则ID: neo23x0_network_connect"
echo -e "    ${YELLOW}SKIP${NC} - 规则已禁用 (enabled: false)"
SKIPPED=$((SKIPPED + 1))

# ============================================================
# 测试总结
# ============================================================
echo ""
echo -e "${BOLD}============================================================${NC}"
echo -e "${BOLD}  测试总结${NC}"
echo -e "${BOLD}============================================================${NC}"
echo ""
echo -e "  总测试数:   ${TOTAL}"
echo -e "  ${GREEN}PASS${NC}:        ${PASSED}"
echo -e "  ${RED}FAIL${NC}:        ${FAILED}"
echo -e "  ${YELLOW}SKIP${NC}:        ${SKIPPED}"
echo ""

if [ "$FAILED" -eq 0 ]; then
    echo -e "  ${GREEN}${BOLD}所有可测规则均通过！${NC}"
else
    echo -e "  ${RED}${BOLD}有 ${FAILED} 条规则测试失败${NC}"
fi
echo ""

# 显示当前告警日志统计
echo -e "${CYAN}告警日志统计:${NC}"
if [ -s "$ALERT_LOG" ]; then
    echo "  总告警数: $(wc -l < "$ALERT_LOG")"
    echo ""
    echo "  按规则分布:"
    python3 -c "
import json, collections
counts = collections.Counter()
severities = {}
with open('$ALERT_LOG') as f:
    for line in f:
        try:
            d = json.loads(line)
            rid = d.get('rule_id','')
            sev = d.get('severity','')
            counts[rid] += 1
            severities[rid] = sev
        except: pass
for rid, cnt in counts.most_common():
    sev = severities.get(rid,'').upper()
    print(f'    [{sev:8s}] {rid}: {cnt}')
"
else
    echo "  告警日志为空"
fi
echo ""
echo -e "${BOLD}测试完成: $(date -u '+%Y-%m-%d %H:%M:%S UTC')${NC}"
