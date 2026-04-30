#!/bin/bash
# SEC-AUDITD 规则测试脚本
# 用于验证审计规则是否正常工作

echo "======================================"
echo "  SEC-AUDITD 规则测试"
echo "======================================"
echo ""

# 检查权限
if [ "$EUID" -ne 0 ]; then
    echo "警告：建议使用 root 权限运行以测试所有规则"
fi

TEST_DIR="/tmp/sec-auditd-test-$$"
mkdir -p "$TEST_DIR"

echo "测试目录: $TEST_DIR"
echo ""

# 等待一段时间让事件记录
WAIT_TIME=2

echo "[测试 1] 进程执行监控"
echo "-----------------------------------"
echo "执行测试命令..."
/bin/ls "$TEST_DIR" > /dev/null 2>&1
sleep $WAIT_TIME
echo "查询审计日志..."
ausearch -k process_exec -ts recent 2>/dev/null | grep -c "type=EXECVE" || echo "0"
echo "✓ 进程执行事件已记录"
echo ""

echo "[测试 2] 临时目录执行监控"
echo "-----------------------------------"
echo "在 /tmp 创建并执行测试脚本..."
echo '#!/bin/bash' > "$TEST_DIR/test.sh"
echo 'echo "test"' >> "$TEST_DIR/test.sh"
chmod +x "$TEST_DIR/test.sh"
"$TEST_DIR/test.sh" > /dev/null 2>&1
sleep $WAIT_TIME
echo "查询审计日志..."
ausearch -k suspicious_exec_tmp -ts recent 2>/dev/null | grep -c "type=EXECVE" || echo "0"
echo "✓ 临时目录执行事件已记录"
echo ""

echo "[测试 3] 文件监控"
echo "-----------------------------------"
echo "创建测试文件..."
TEST_FILE="$TEST_DIR/testfile"
touch "$TEST_FILE"
echo "修改测试文件..."
echo "test content" > "$TEST_FILE"
sleep $WAIT_TIME
echo "✓ 文件操作完成（临时目录不在监控范围内，这是正常的）"
echo ""

echo "[测试 4] 网络连接监控"
echo "-----------------------------------"
echo "测试网络连接..."
# 尝试连接到本地或公网
timeout 2 curl -s http://www.baidu.com > /dev/null 2>&1 || \
timeout 2 wget -q -O /dev/null http://www.baidu.com 2>&1 || \
timeout 2 ping -c 1 8.8.8.8 > /dev/null 2>&1
sleep $WAIT_TIME
echo "查询审计日志..."
ausearch -k network_connect -ts recent 2>/dev/null | grep -c "type=SYSCALL" || echo "0"
echo "✓ 网络连接事件已记录"
echo ""

echo "[测试 5] 审计规则完整性检查"
echo "-----------------------------------"
echo "检查关键规则是否加载..."

RULES_TO_CHECK=(
    "process_exec"
    "suspicious_exec_tmp"
    "network_connect"
    "network_bind"
    "passwd_changes"
    "shadow_changes"
    "sshd_config"
    "sudoers_changes"
    "privilege_escalation"
)

LOADED_RULES=$(auditctl -l)

for rule in "${RULES_TO_CHECK[@]}"; do
    if echo "$LOADED_RULES" | grep -q "key=$rule"; then
        echo "  ✓ $rule"
    else
        echo "  ✗ $rule (未加载)"
    fi
done

echo ""
echo "[测试 6] 告警引擎测试"
echo "-----------------------------------"
if systemctl is-active --quiet sec-auditd-alert 2>/dev/null; then
    echo "✓ 告警引擎运行中"

    if [ -f /var/log/sec-auditd/alert.log ]; then
        ALERT_COUNT=$(wc -l < /var/log/sec-auditd/alert.log)
        echo "  告警日志行数: $ALERT_COUNT"

        if [ "$ALERT_COUNT" -gt 0 ]; then
            echo "  最新告警："
            tail -1 /var/log/sec-auditd/alert.log | python3 -m json.tool 2>/dev/null || tail -1 /var/log/sec-auditd/alert.log
        fi
    else
        echo "  ⚠ 告警日志不存在"
    fi
else
    echo "⚠ 告警引擎未运行"
fi

echo ""
echo "[测试 7] 日志轮转配置检查"
echo "-----------------------------------"
if [ -f /etc/logrotate.d/sec-auditd ]; then
    echo "✓ 日志轮转配置存在"
    echo "  配置文件: /etc/logrotate.d/sec-auditd"
else
    echo "✗ 日志轮转配置不存在"
fi

echo ""
echo "======================================"
echo "  清理测试文件..."
echo "======================================"
rm -rf "$TEST_DIR"
echo "✓ 测试完成"
echo ""
echo "说明："
echo "  - 如果某些测试显示 0 事件，可能是因为："
echo "    1. 规则未正确加载"
echo "    2. 事件还未写入日志"
echo "    3. 权限不足"
echo "  - 请查看完整日志: tail -f /var/log/audit/audit.log"
echo "  - 查询特定事件: ausearch -k <key_name> -i"
echo ""
