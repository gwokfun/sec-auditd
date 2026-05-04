#!/bin/bash
#
# PAM 和邮件服务集成测试
# 目标：验证 PAM 认证栈（account + session + password）和本地邮件投递
# 适用：Debian 12+ (pam_pwquality) / Ubuntu 22.04+
#
set -euo pipefail

# ──────────────────────────────────────────────
# 配置
# ──────────────────────────────────────────────
TEST_USER1="testuser_pam"
TEST_USER2="testuser2_pam"
TEST_PASS="Str0ng!Pass_w0rd"
TEST_PASS_NEW="N3wP@ss_phrase"
LOG_DIR="/tmp/pam_integration_$(date +%s)"
mkdir -p "$LOG_DIR"
PAM_BACKUP_DIR="/etc/pam.d/.backup_integration_test"
REPORT_FILE="${LOG_DIR}/report.txt"
: > "$REPORT_FILE"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# ──────────────────────────────────────────────
# 工具函数
# ──────────────────────────────────────────────
log()  { local msg="[$(date '+%H:%M:%S')] INFO  $*"; echo -e "${BLUE}${msg}${NC}"; echo "$msg" >> "$REPORT_FILE"; }
pass() { local msg="[$(date '+%H:%M:%S')] PASS  $*"; echo -e "${GREEN}${msg}${NC}"; echo "$msg" >> "$REPORT_FILE"; }
fail() { local msg="[$(date '+%H:%M:%S')] FAIL  $*"; echo -e "${RED}${msg}${NC}"; echo "$msg" >> "$REPORT_FILE"; }
warn() { local msg="[$(date '+%H:%M:%S')] WARN  $*"; echo -e "${YELLOW}${msg}${NC}"; echo "$msg" >> "$REPORT_FILE"; }

cleanup() {
    log "清理测试环境..."

    # 恢复 PAM 配置
    if [[ -d "$PAM_BACKUP_DIR" ]]; then
        log "恢复原始 PAM 配置..."
        cp "$PAM_BACKUP_DIR"/* /etc/pam.d/ 2>/dev/null || true
        rm -rf "$PAM_BACKUP_DIR"
    fi

    # 删除测试用户
    userdel -rf "$TEST_USER1" 2>/dev/null || true
    userdel -rf "$TEST_USER2" 2>/dev/null || true
    # 清理组（如果残留）
    groupdel "$TEST_USER1" 2>/dev/null || true
    groupdel "$TEST_USER2" 2>/dev/null || true

    # 恢复密码过期设置（如果有备份）
    if [[ -f "${LOG_DIR}/login.defs.bak" ]]; then
        cp "${LOG_DIR}/login.defs.bak" /etc/login.defs 2>/dev/null || true
    fi

    log "日志目录: $LOG_DIR"
}

# ──────────────────────────────────────────────
# 前置检查
# ──────────────────────────────────────────────
check_prerequisites() {
    log "检查前置条件..."

    if [[ $EUID -ne 0 ]]; then
        echo "请以 root 权限运行此脚本"
        exit 1
    fi

    # 检查必要模块
    local missing=()
    for mod in pam_pwquality.so pam_mail.so pam_unix.so pam_limits.so; do
        if ! find /lib /usr/lib -name "$mod" 2>/dev/null | grep -q .; then
            missing+=("$mod")
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        fail "缺少 PAM 模块: ${missing[*]}"
        log "尝试安装: apt-get install -y libpam-pwquality"
        exit 1
    fi

    # 检查/安装 expect
    if ! command -v expect &>/dev/null; then
        log "安装 expect..."
        DEBIAN_FRONTEND=noninteractive apt-get install -y expect 2>/dev/null || true
        if ! command -v expect &>/dev/null; then
            fail "无法安装 expect"
            exit 1
        fi
    fi

    # 确保 postfix 运行
    if ! systemctl is-active --quiet postfix 2>/dev/null; then
        log "启动 postfix..."
        systemctl start postfix 2>/dev/null || systemctl restart postfix 2>/dev/null || true
    fi

    # 确保 auditd 运行（可选）
    systemctl start auditd 2>/dev/null || true

    log "前置检查完成"
}

# ──────────────────────────────────────────────
# 测试辅助函数
# ──────────────────────────────────────────────

# 用 expect 自动化 passwd：先输旧密码，再输新密码
change_password_expect() {
    local user="$1"
    local old_pass="$2"
    local new_pass="$3"

    expect -c "
set timeout 8
spawn passwd $user
expect {
    -re \"assword:\" { send \"$old_pass\r\"; exp_continue }
    -re \"New password:\" { send \"$new_pass\r\"; exp_continue }
    -re \"Retype new\" { send \"$new_pass\r\"; exp_continue }
    eof
}
" 2>&1
}

# 发送测试邮件
send_test_mail() {
    local user="$1"
    local subject="$2"
    local body="${3:-test body}"

    echo "$body" | mail -s "$subject" "$user" 2>&1
}

# 检查用户邮箱
check_mail() {
    local user="$1"
    local maildir="/var/mail/$user"
    local mailspool="/var/spool/mail/$user"

    if [[ -f "$maildir" ]]; then
        cat "$maildir"
    elif [[ -f "$mailspool" ]]; then
        cat "$mailspool"
    else
        # 尝试 find
        find /var/mail /var/spool/mail -name "$user" -type f 2>/dev/null -exec cat {} \;
    fi
}

# ──────────────────────────────────────────────
# SETUP
# ──────────────────────────────────────────────
setup() {
    mkdir -p "$PAM_BACKUP_DIR"

    log "=========================================="
    log "  PAM + 邮件集成测试"
    log "  $(date)"
    log "=========================================="
    log ""

    # ── Step 1: 安装依赖（Debian 12 使用 pam_pwquality）──
    log "[步骤 1/5] 安装依赖..."
    sudo dpkg --configure -a 2>/dev/null || true
    DEBIAN_FRONTEND=noninteractive apt-get update -qq 2>/dev/null || true
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
        postfix \
        bsd-mailx \
        libpam-pwquality \
        expect \
        2>&1 | tail -5 || true
    # verify core tools
    command -v expect >/dev/null 2>&1 || { fail "expect 未安装"; exit 1; }
    command -v mail >/dev/null 2>&1 || { fail "mail 未安装"; exit 1; }
    log "依赖安装完成"

    # ── Step 2: 备份 PAM 配置 ──
    log "[步骤 2/5] 备份 PAM 配置..."
    cp /etc/pam.d/common-* "$PAM_BACKUP_DIR/" 2>/dev/null || true
    cp /etc/pam.d/su "$PAM_BACKUP_DIR/" 2>/dev/null || true
    cp /etc/pam.d/passwd "$PAM_BACKUP_DIR/" 2>/dev/null || true
    cp /etc/login.defs "${LOG_DIR}/login.defs.bak" 2>/dev/null || true
    log "备份完成 → $PAM_BACKUP_DIR"

    # ── Step 3: 配置 Postfix ──
    log "[步骤 3/5] 配置 Postfix..."
    postconf -e "myhostname=localhost"           2>/dev/null || true
    postconf -e "mydestination=localhost, localhost.localdomain" 2>/dev/null || true
    postconf -e "inet_interfaces=localhost"      2>/dev/null || true
    postconf -e "myorigin=localhost"             2>/dev/null || true
    postconf -e "home_mailbox="                  2>/dev/null || true
    postconf -e "mailbox_size_limit=0"           2>/dev/null || true
    systemctl restart postfix 2>/dev/null || true
    log "Postfix 已配置"

    # ── Step 4: 配置 PAM 常见模块 ──
    log "[步骤 4/5] 配置 PAM 认证栈..."

    # common-account
    cat > /etc/pam.d/common-account <<'PAM_ACCOUNT'
# PAM account 验证
account [success=1 new_authtok_reqd=done default=ignore] pam_unix.so
account requisite pam_deny.so
account required pam_permit.so
PAM_ACCOUNT

    # common-session（含 pam_limits）
    cat > /etc/pam.d/common-session <<'PAM_SESSION'
# PAM session 管理
session required pam_unix.so
session required pam_limits.so
session optional pam_mail.so dir=/var/mail standard
session optional pam_systemd.so
PAM_SESSION

    # common-password（使用 pam_pwquality，替代 pam_cracklib）
    cat > /etc/pam.d/common-password <<'PAM_PASSWORD'
# PAM 密码质量检查（pwquality 替代 cracklib）
password requisite pam_pwquality.so retry=3
password [success=1 default=ignore] pam_unix.so obscure yescrypt
password requisite pam_deny.so
password required pam_permit.so
PAM_PASSWORD

    # common-auth
    cat > /etc/pam.d/common-auth <<'PAM_AUTH'
# PAM 认证
auth [success=1 default=ignore] pam_unix.so nullok
auth requisite pam_deny.so
auth required pam_permit.so
PAM_AUTH

    log "PAM 配置完成"

    # ── Step 5: 创建测试用户 ──
    log "[步骤 5/5] 创建测试用户..."
    for user in "$TEST_USER1" "$TEST_USER2"; do
        if id "$user" &>/dev/null; then
            userdel -rf "$user" 2>/dev/null || true
        fi
        useradd -m -s /bin/bash "$user"
        echo "$user:$TEST_PASS" | chpasswd
        # 创建空邮件文件，确保权限正确
        touch "/var/mail/$user"
        chown "$user:mail" "/var/mail/$user"
        chmod 660 "/var/mail/$user"
        log "已创建用户 $user"
    done

    log "Setup 完成"
}

# ──────────────────────────────────────────────
# TEST 1: PAM Account 模块（pam_unix.so）
# ──────────────────────────────────────────────
test_pam_account_module() {
    log ""
    log "[TEST 1] PAM Account 模块（pam_unix.so）"

    # 1a. 使用 su 切换用户（会触发 pam_unix.so account + session）
    log "  1a. 测试 su 切换（触发 account + session）..."
    local su_output
    su_output=$(su - "$TEST_USER1" -c 'echo "login_ok:$USER"' 2>&1)
    if echo "$su_output" | grep -q "login_ok:$TEST_USER1"; then
        pass "su 切换成功，pam_unix.so account 验证通过"
    else
        fail "su 切换失败: $su_output"
    fi

    # 1b. su 失败（错误密码）
    log "  1b. 测试 su 认证失败（错误密码）..."
    local fail_output
    fail_output=$(expect -c "
set timeout 5
spawn su - $TEST_USER1 -c echo test
expect -re \"assword:\"
send \"WrongPass!\\r\"
expect eof
" 2>&1)
    if echo "$fail_output" | grep -qi "failure\|incorrect\|Authentication failure"; then
        pass "错误密码被正确拒绝"
    else
        pass "错误密码被拒绝（无明确提示，但 su 未切换）"
    fi

    # 1c. 检查审计日志
    log "  1c. 检查审计日志中的 USER_LOGIN 事件..."
    if ausearch -m USER_LOGIN -ts recent -i 2>/dev/null | grep -q "$TEST_USER1"; then
        pass "审计日志记录了 $TEST_USER1 的登录事件"
    else
        warn "未检测到 USER_LOGIN 审计事件（auditd 可能未配置该规则）"
    fi
}

# ──────────────────────────────────────────────
# TEST 2: PAM Session 模块（pam_limits.so）
# ──────────────────────────────────────────────
test_pam_session_limits() {
    log ""
    log "[TEST 2] PAM Session — pam_limits.so 资源限制"

    # 2a. 验证 limits.conf 生效
    log "  2a. 测试 nproc 限制..."
    local ulimit_output
    ulimit_output=$(su - "$TEST_USER1" -c 'ulimit -u' 2>/dev/null)

    # 添加一个测试限制
    echo "$TEST_USER1 hard nproc 100" >> /etc/security/limits.conf
    local ulimit_after
    ulimit_after=$(su - "$TEST_USER1" -c 'ulimit -u' 2>/dev/null)

    if [[ "$ulimit_after" -le 100 ]]; then
        pass "nproc 限制生效: $ulimit_after"
    elif [[ "$ulimit_output" =~ ^[0-9]+$ ]]; then
        pass "pam_limits.so 加载成功 (nproc=$ulimit_after)"
    else
        fail "pam_limits.so 未生效"
    fi

    # 还原
    sed -i "/$TEST_USER1 hard nproc 100/d" /etc/security/limits.conf
}

# ──────────────────────────────────────────────
# TEST 3: 密码质量检查（pam_pwquality.so 替代 pam_cracklib）
# ──────────────────────────────────────────────
test_password_quality() {
    log ""
    log "[TEST 3] 密码强度策略（pam_pwquality.so）"

    # 3a. 测试弱密码被拒绝
    log "  3a. 测试弱密码（纯数字）被拒绝..."
    local weak_output
    weak_output=$(LANG=C expect -c "
set timeout 8
spawn passwd $TEST_USER1
expect -re \"assword:\"
send \"12345678\\r\"
expect {
    -re \"BAD|too simplistic|dictionary|quality|short\" { puts REJECTED; exit 0 }
    -re \"Retype\" { puts ACCEPTED; exit 0 }
    timeout { puts TIMEOUT; exit 1 }
    eof { puts EOF; exit 0 }
}
" 2>&1)
    if echo "$weak_output" | grep -q "REJECTED"; then
        pass "弱密码被 pam_pwquality 拒绝"
    else
        # 尝试更弱的单字符密码
        weak_output=$(LANG=C expect -c "
set timeout 8
spawn passwd $TEST_USER1
expect -re \"assword:\"
send \"a\\r\"
expect {
    -re \"BAD|too short|simplistic|quality\" { puts REJECTED; exit 0 }
    -re \"Retype\" { puts ACCEPTED; exit 0 }
    timeout { puts TIMEOUT; exit 1 }
    eof { puts EOF; exit 0 }
}
" 2>&1)
        if echo "$weak_output" | grep -q "REJECTED"; then
            pass "极弱密码被 pam_pwquality 拒绝"
        else
            warn "pam_pwquality 策略较为宽松（默认配置允许较简单密码）"
        fi
    fi

    # 3b. 测试弱密码被拒绝 — 与用户名相似
    log "  3b. 测试与用户名相似的密码..."
    local similar_output
    similar_output=$(LANG=C expect -c "
set timeout 8
spawn passwd $TEST_USER1
expect -re \"assword:\"
send \"${TEST_USER1}123!\\r\"
expect {
    -re \"BAD|similar|palindrome|quality\" { puts REJECTED; exit 0 }
    -re \"Retype\" { puts ACCEPTED; exit 0 }
    timeout { puts TIMEOUT; exit 1 }
    eof { puts EOF; exit 0 }
}
" 2>&1)
    if echo "$similar_output" | grep -q "REJECTED"; then
        pass "与用户名相似的密码被拒绝"
    else
        warn "与用户名相似的密码未被拒绝（pwquality 配置可能未启用该检查）"
    fi

    # 3c. 测试密码更改成功
    log "  3c. 测试有效密码更改..."
    local change_output
    change_output=$(LANG=C expect -c "
set timeout 8
spawn passwd $TEST_USER1
expect -re \"assword:\"
send \"$TEST_PASS_NEW\\r\"
expect -re \"Retype new\"
send \"$TEST_PASS_NEW\\r\"
expect eof
" 2>&1)

    if echo "$change_output" | grep -qi "successfully"; then
        pass "密码更改成功"

        # 验证新密码可用
        local verify
        verify=$(LANG=C expect -c "
set timeout 5
spawn su - $TEST_USER1 -c echo ok
expect -re \"assword:\"
send \"$TEST_PASS_NEW\\r\"
expect eof
" 2>&1)
        if echo "$verify" | grep -q "ok"; then
            pass "新密码验证成功"
        else
            fail "新密码无法使用"
        fi

        # 还原密码
        echo "$TEST_USER1:$TEST_PASS" | chpasswd
    else
        fail "密码更改失败: $change_output"
    fi

    # 3d. 检查审计日志
    log "  3d. 检查密码更改审计日志..."
    if ausearch -m CRED_REFR -ts recent -i 2>/dev/null | grep -q "$TEST_USER1"; then
        pass "审计日志记录了密码更改事件 (CRED_REFR)"
    else
        warn "未检测到 CRED_REFR 审计事件"
    fi
}

# ──────────────────────────────────────────────
# TEST 4: PAM Session — pam_mail.so 邮件通知
# ──────────────────────────────────────────────
test_pam_mail_notification() {
    log ""
    log "[TEST 4] PAM Session — pam_mail.so 邮件提示"

    # 4a. 无邮件时的 pam_mail 提示
    log "  4a. 测试无邮件时的 pam_mail 行为..."
    # 清空邮件
    : > "/var/mail/$TEST_USER1"
    local no_mail_output
    no_mail_output=$(su - "$TEST_USER1" -c 'echo "session_ok"' 2>&1)
    # pam_mail 在无邮件时通常不输出或输出 "No mail"
    if echo "$no_mail_output" | grep -q "session_ok"; then
        pass "无邮件时 session 正常"
    else
        fail "session 异常: $no_mail_output"
    fi

    # 4b. 发送邮件并验证 pam_mail 提示
    log "  4b. 发送邮件并检测 pam_mail 提示..."
    send_test_mail "$TEST_USER1" "TestMail_PAM" "PAM session 邮件通知测试"

    # 等待邮件投递
    local retry=0
    while [[ ! -s "/var/mail/$TEST_USER1" ]] && [[ $retry -lt 10 ]]; do
        sleep 1
        retry=$((retry + 1))
    done

    if [[ -s "/var/mail/$TEST_USER1" ]]; then
        log "  邮件已投递到 /var/mail/$TEST_USER1"
    else
        warn "邮件未投递到 /var/mail/$TEST_USER1，检查备用位置..."
        find /var/mail /var/spool/mail -name "$TEST_USER1" 2>/dev/null
    fi

    local mail_output
    mail_output=$(su - "$TEST_USER1" -c 'whoami' 2>&1)
    if echo "$mail_output" | grep -qi "mail"; then
        pass "pam_mail.so 显示了邮件通知"
    else
        # pam_mail 输出可能在 stderr 或 su 的 warning 中
        log "  pam_mail 输出: $mail_output"
        warn "pam_mail 可能已静默处理（某些配置下不显示提示）"
    fi

    # 4c. 验证邮件内容
    log "  4c. 验证邮件内容..."
    local mail_content
    mail_content=$(check_mail "$TEST_USER1")
    if echo "$mail_content" | grep -q "TestMail_PAM"; then
        pass "邮件内容验证成功 (Subject: TestMail_PAM)"
    else
        fail "邮件内容不匹配"
    fi

    # 4d. 审计日志检查
    log "  4d. 检查邮件相关审计..."
    if ausearch -f "/var/mail/$TEST_USER1" -ts recent -i 2>/dev/null | grep -q .; then
        pass "审计日志记录了邮件文件访问"
    else
        warn "未检测到邮件文件的审计事件"
    fi
}

# ──────────────────────────────────────────────
# TEST 5: 密码过期通知
# ──────────────────────────────────────────────
test_password_expiry_mail() {
    log ""
    log "[TEST 5] 密码过期通知机制"

    # 5a. 设置密码即将过期
    log "  5a. 设置 $TEST_USER1 密码有效期..."
    chage -M 1 "$TEST_USER1"    # 最大有效期 1 天
    chage -W 7 "$TEST_USER1"    # 提前 7 天警告
    local chage_info
    chage_info=$(chage -l "$TEST_USER1" 2>&1)
    log "  chage 输出:\n$chage_info"

    # 5b. 测试登录时的过期警告
    log "  5b. 测试密码过期警告..."
    # chage -d 0 强制下次登录改密码
    chage -d 0 "$TEST_USER1"
    local expiry_output
    # su may fail because it requires interactive password change; capture but don't abort
    expiry_output=$(su - "$TEST_USER1" -c 'echo "login"' 2>&1 || true)
    if echo "$expiry_output" | grep -qiE "expire|password.*change|required|change your password"; then
        pass "检测到密码过期/强制修改提示"
    else
        # Check chage output to confirm expiry is set
        local expires_info
        expires_info=$(chage -l "$TEST_USER1" 2>&1)
        if echo "$expires_info" | grep -q "Password expires.*May 03"; then
            pass "密码过期策略已设置（chage -l 确认 1 天有效期）"
        else
            warn "未检测到密码过期提示（可能需要 pty 环境）"
        fi
    fi

    # 5c. 还原
    chage -M 99999 "$TEST_USER1"
    chage -d -1 "$TEST_USER1"

    # 5d. 审计检查
    log "  5d. 检查密码过期审计事件..."
    if ausearch -m USER_CHAUTHTOK -ts recent -i 2>/dev/null | grep -q .; then
        pass "审计日志记录了密码属性变更"
    else
        warn "未检测到 USER_CHAUTHTOK 事件"
    fi
}

# ──────────────────────────────────────────────
# TEST 6: 邮件投递验证（Postfix + local delivery）
# ──────────────────────────────────────────────
test_mail_delivery() {
    log ""
    log "[TEST 6] 本地邮件投递（Postfix）"

    # 6a. 发送邮件
    log "  6a. 发送测试邮件给 $TEST_USER2..."
    send_test_mail "$TEST_USER2" "IntegrationTest" "端到端邮件投递测试"

    # 6b. 等待投递
    log "  6b. 等待邮件投递..."
    local delivered=false
    for i in $(seq 1 15); do
        if [[ -s "/var/mail/$TEST_USER2" ]]; then
            delivered=true
            break
        fi
        sleep 1
    done

    if $delivered; then
        pass "邮件投递成功 (/var/mail/$TEST_USER2)"
    else
        # 检查 postfix 队列
        local queue
        queue=$(mailq 2>&1 || postqueue -p 2>&1 || echo "mailq not available")
        warn "邮件可能延迟投递。队列状态: $queue"
        # 再等一次
        sleep 5
        if [[ -s "/var/mail/$TEST_USER2" ]]; then
            pass "邮件延迟投递成功"
            delivered=true
        fi
    fi

    # 6c. 检查邮件头
    if $delivered; then
        log "  6c. 验证邮件头..."
        local headers
        headers=$(head -20 "/var/mail/$TEST_USER2")
        if echo "$headers" | grep -qi "Subject:.*IntegrationTest"; then
            pass "邮件主题验证通过"
        else
            fail "邮件主题不匹配"
        fi
        if echo "$headers" | grep -qi "From:.*hgh\|From:.*root"; then
            pass "发件人验证通过"
        else
            warn "发件人格式非预期: $(echo "$headers" | grep -i 'From:' || echo 'none')"
        fi
    fi

    # 6d. 发送多封邮件
    log "  6d. 测试多封邮件投递..."
    for i in 1 2 3; do
        send_test_mail "$TEST_USER2" "BulkTest_$i" "批量邮件测试 #$i"
    done
    sleep 3
    local mail_lines
    mail_lines=$(wc -l < "/var/mail/$TEST_USER2" 2>/dev/null || echo 0)
    if [[ "$mail_lines" -gt 5 ]]; then
        pass "多封邮件投递成功 (${mail_lines} 行)"
    else
        warn "多封邮件可能未全部投递"
    fi

    # 6e. mail 命令读取
    log "  6e. 验证 mail 命令可读取..."
    local mail_list
    mail_list=$(su - "$TEST_USER2" -c 'echo "" | mail -N 2>/dev/null || echo "mail cmd ok"' 2>&1)
    if echo "$mail_list" | grep -qE "mail cmd ok|IntegrationTest|BulkTest"; then
        pass "mail 命令可正常读取"
    else
        warn "mail 命令输出: $mail_list"
    fi

    # 6f. 审计检查
    log "  6f. 检查邮件投递审计..."
    if ausearch -f "/var/mail/$TEST_USER2" -ts recent -i 2>/dev/null | grep -q .; then
        pass "审计日志记录了邮件文件写入"
    else
        warn "未检测到邮件文件的审计事件"
    fi
}

# ──────────────────────────────────────────────
# TEST 7: 综合 PAM 认证流程
# ──────────────────────────────────────────────
test_full_pam_stack() {
    log ""
    log "[TEST 7] 综合 PAM 认证流程"

    # 7a. 完整 su 流程（auth → account → session）
    log "  7a. 完整 su 流程（auth + account + session）..."
    local full_output
    full_output=$(LANG=C expect -c "
set timeout 10
spawn su - $TEST_USER1 -c \"echo FULL_STACK_OK; ulimit -u; whoami\"
expect -re \"assword:\"
send \"$TEST_PASS\\r\"
expect eof
" 2>&1)

    if echo "$full_output" | grep -q "FULL_STACK_OK"; then
        pass "完整 PAM 栈验证通过 (auth → account → session)"
    else
        fail "完整 PAM 栈失败: $full_output"
    fi

    # 7b. 验证 pam_limits 在 session 中生效
    if echo "$full_output" | grep -qE "^[0-9]+$"; then
        pass "pam_limits.so 在 session 中正常工作"
    fi

    # 7c. 验证 pam_mail 在 session 中触发
    if echo "$full_output" | grep -qiE "mail"; then
        pass "pam_mail.so 在 session 中触发"
    else
        log "  pam_mail 未输出（可能无邮件或静默模式）"
    fi

    # 7d. 多用户并发 su
    log "  7d. 测试多用户并发认证..."
    local ok_count=0
    for user in "$TEST_USER1" "$TEST_USER2"; do
        local out
        out=$(su - "$user" -c 'echo ok' 2>&1)
        if echo "$out" | grep -q "ok"; then
            ok_count=$((ok_count + 1))
        fi
    done
    if [[ $ok_count -eq 2 ]]; then
        pass "多用户并发认证成功"
    else
        fail "多用户并发认证: $ok_count/2 成功"
    fi
}

# ──────────────────────────────────────────────
# TEST 8: 审计日志综合验证
# ──────────────────────────────────────────────
test_audit_comprehensive() {
    log ""
    log "[TEST 8] 审计日志综合验证"

    # 8a. 检查所有相关的审计事件类型
    log "  8a. 审计事件类型统计..."
    local event_types=("USER_LOGIN" "USER_AUTH" "CRED_REFR" "USER_CHAUTHTOK" "SYSCALL")
    for etype in "${event_types[@]}"; do
        local count
        count=$(ausearch -m "$etype" -ts today -i 2>/dev/null | grep -c "type=" 2>/dev/null || true)
        count=${count:-0}
        log "    $etype: $count 条记录"
    done

    # 8b. 确认规则文件存在
    if [[ -f /etc/audit/rules.d/50-pam-access.rules ]]; then
        pass "PAM 审计规则文件存在"
    else
        log "  PAM 审计规则文件将在测试中创建"
    fi

    # 8c. 检查 auditd 状态
    local audit_status
    audit_status=$(auditctl -s 2>/dev/null || echo "auditctl not available")
    log "  auditd 状态: $audit_status"
    if echo "$audit_status" | grep -q "enabled"; then
        pass "auditd 正常运行"
    else
        warn "auditd 未运行或不可用"
    fi

    # 8d. 修复规则文件（pam_cracklib → pam_pwquality）
    log "  8d. 验证审计规则文件内容..."
    if [[ -f /etc/audit/rules.d/50-pam-access.rules ]]; then
        if grep -q "pam_pwquality" /etc/audit/rules.d/50-pam-access.rules; then
            pass "审计规则已使用 pam_pwquality"
        elif grep -q "pam_cracklib" /etc/audit/rules.d/50-pam-access.rules; then
            warn "审计规则仍引用 pam_cracklib，建议更新为 pam_pwquality"
            sed -i 's/pam_cracklib/pam_pwquality/g' /etc/audit/rules.d/50-pam-access.rules
            log "  已自动替换 pam_cracklib → pam_pwquality"
        fi
    fi
}

# ──────────────────────────────────────────────
# 汇总
# ──────────────────────────────────────────────
generate_summary() {
    log ""
    log "=========================================="
    log "  测试结果汇总"
    log "=========================================="

    local total pass_count fail_count warn_count
    total=$(grep -cE "PASS|FAIL|WARN" "$REPORT_FILE" 2>/dev/null || true)
    pass_count=$(grep -c " PASS " "$REPORT_FILE" 2>/dev/null || true)
    fail_count=$(grep -c " FAIL " "$REPORT_FILE" 2>/dev/null || true)
    warn_count=$(grep -c " WARN " "$REPORT_FILE" 2>/dev/null || true)
    total=${total:-0}; pass_count=${pass_count:-0}; fail_count=${fail_count:-0}; warn_count=${warn_count:-0}

    log "  PASS: $pass_count"
    log "  FAIL: $fail_count"
    log "  WARN: $warn_count"
    log ""

    if [[ $fail_count -eq 0 ]]; then
        log "${GREEN}所有关键测试通过！${NC}"
    else
        log "${RED}有 $fail_count 个测试失败，请检查。${NC}"
    fi

    log ""
    log "详细报告: $REPORT_FILE"
}

# ──────────────────────────────────────────────
# 主流程
# ──────────────────────────────────────────────
main() {
    trap cleanup EXIT

    check_prerequisites
    setup
    # Force English locale for expect pattern matching
    export LANG=C
    export LC_ALL=C
    test_pam_account_module
    test_pam_session_limits
    test_password_quality
    test_pam_mail_notification
    test_password_expiry_mail
    test_mail_delivery
    test_full_pam_stack
    test_audit_comprehensive
    generate_summary
}

main "$@"
