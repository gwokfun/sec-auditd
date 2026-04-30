#!/bin/bash
# SEC-AUDITD 状态检查脚本

echo "======================================"
echo "  SEC-AUDITD 状态检查"
echo "======================================"
echo ""

# 检查 auditd 服务状态
echo "[1] Auditd 服务状态:"
echo "-----------------------------------"
if systemctl is-active --quiet auditd; then
    echo "✓ auditd 服务运行中"
    systemctl status auditd --no-pager | head -5
else
    echo "✗ auditd 服务未运行"
    echo "  启动命令: systemctl start auditd"
fi

echo ""
echo "[2] 已加载的审计规则:"
echo "-----------------------------------"
RULE_COUNT=$(auditctl -l 2>/dev/null | wc -l)
if [ "$RULE_COUNT" -gt 0 ]; then
    echo "✓ 已加载 $RULE_COUNT 条规则"
    echo ""
    echo "规则统计："
    auditctl -l | grep -o 'key=[^ ]*' | sort | uniq -c | head -10
else
    echo "✗ 没有加载任何规则"
    echo "  加载规则: auditctl -R /etc/audit/rules.d/sec-auditd.rules"
fi

echo ""
echo "[3] 审计日志:"
echo "-----------------------------------"
if [ -f /var/log/audit/audit.log ]; then
    LOG_SIZE=$(du -h /var/log/audit/audit.log | cut -f1)
    LOG_LINES=$(wc -l < /var/log/audit/audit.log)
    echo "✓ 审计日志存在"
    echo "  文件大小: $LOG_SIZE"
    echo "  行数: $LOG_LINES"
    echo "  路径: /var/log/audit/audit.log"
else
    echo "✗ 审计日志不存在"
fi

echo ""
echo "[4] 最近的审计事件 (最近10条):"
echo "-----------------------------------"
if command -v ausearch &> /dev/null; then
    ausearch -ts recent -i 2>/dev/null | grep "type=" | head -10 || echo "  没有最近的事件"
else
    tail -10 /var/log/audit/audit.log 2>/dev/null || echo "  无法读取日志"
fi

echo ""
echo "[5] 审计日志磁盘使用:"
echo "-----------------------------------"
du -sh /var/log/audit/ 2>/dev/null || echo "  无法读取"

echo ""
echo "[6] Auditd 配置:"
echo "-----------------------------------"
if [ -f /etc/audit/auditd.conf ]; then
    echo "关键配置项："
    grep -E "^(log_file|num_logs|max_log_file|max_log_file_action)" /etc/audit/auditd.conf
else
    echo "配置文件不存在"
fi

echo ""
echo "[7] 告警引擎状态:"
echo "-----------------------------------"
if systemctl list-unit-files | grep -q sec-auditd-alert; then
    if systemctl is-active --quiet sec-auditd-alert; then
        echo "✓ 告警引擎运行中"
        systemctl status sec-auditd-alert --no-pager | head -5
    else
        echo "✗ 告警引擎未运行"
        echo "  启动命令: systemctl start sec-auditd-alert"
    fi
else
    echo "⚠ 告警引擎未安装"
fi

echo ""
echo "[8] 告警日志:"
echo "-----------------------------------"
if [ -f /var/log/sec-auditd/alert.log ]; then
    ALERT_COUNT=$(wc -l < /var/log/sec-auditd/alert.log)
    ALERT_SIZE=$(du -h /var/log/sec-auditd/alert.log | cut -f1)
    echo "✓ 告警日志存在"
    echo "  文件大小: $ALERT_SIZE"
    echo "  告警数: $ALERT_COUNT"
    echo "  路径: /var/log/sec-auditd/alert.log"

    if [ "$ALERT_COUNT" -gt 0 ]; then
        echo ""
        echo "  最近5条告警："
        tail -5 /var/log/sec-auditd/alert.log | python3 -m json.tool 2>/dev/null || tail -5 /var/log/sec-auditd/alert.log
    fi
else
    echo "⚠ 告警日志不存在（可能还没有产生告警）"
fi

echo ""
echo "[9] 系统资源占用:"
echo "-----------------------------------"
echo "Auditd 进程:"
ps aux | grep -E '[a]uditd|[s]ec-auditd' | awk '{printf "  PID: %-6s CPU: %-5s MEM: %-5s CMD: %s\n", $2, $3"%", $4"%", $11}'

echo ""
echo "======================================"
echo "  检查完成"
echo "======================================"
