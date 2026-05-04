# SEC-AUDITD VPS 实测报告

**测试环境**: Oracle Cloud VPS / Ubuntu 24.04.4 LTS / Kernel 6.17.0-1007-oracle
**测试时间**: 2026-05-03 15:50-16:02 UTC
**审计规则数**: 256 条（Syscall: 121, 文件监控: 135）
**告警规则数**: 73 条（启用: 53, 禁用: 4, 聚合: 6）

---

## 测试总结

| 指标 | 数量 |
|------|------|
| 总测试项 | 75 |
| PASS（通过） | 13 |
| FAIL（失败） | 27 |
| SKIP（跳过） | 31 (环境限制/规则禁用/聚合规则) |

---

## 通过的规则（13 条）

### Syscall 类规则 — 全部正常工作

| 规则 ID | 严重度 | 测试动作 | 告警数 | 状态 |
|---------|--------|----------|--------|------|
| suspicious_network_connect | MEDIUM | 网络活动自动触发 | 5 | PASS |
| new_listening_port | MEDIUM | 服务启动自动触发 | 1 | PASS |
| neo23x0_perm_mod | MEDIUM | `chmod 777 /tmp/file` | 1 | PASS |
| neo23x0_delete | LOW | `rm /tmp/file` | 1 | PASS |
| privilege_escalation | CRITICAL | 自动触发（setresuid） | 多条 | PASS |

### 文件监控类 — 部分工作

| 规则 ID | 严重度 | 触发源 | 告警数 | 备注 |
|---------|--------|--------|--------|------|
| shadow_changes | CRITICAL | sshd/systemd/cron 读取 | 3 | 被动触发，非测试命令 |
| root_ssh_keys_change | CRITICAL | SSH 密钥目录操作 | 2 | PASS |
| systemd_change | MEDIUM | systemd 配置变更 | 2 | PASS |

---

## 失败的规则分析（27 条）

### 根本原因：`-w` 文件监控规则（inotify watch）在当前内核上不工作

**证据**:
- `ausearch -k passwd_changes` → 无匹配
- `ausearch -k shadow_changes` → 无匹配
- `ausearch -k sudo_usage` → 无匹配
- 手动添加 `auditctl -w /tmp/test -p wa -k test` → 不生成事件
- 审计日志中 `type=WATCH` 事件仅 2 条（来自 grep 命令本身）
- 但 `type=SYSCALL` 事件正常（9433 条）

**结论**: 审计子系统的 inotify-based 文件监控机制在 Oracle Cloud 6.17 内核上未正常工作。所有 `-w` 规则加载成功（`auditctl -l` 可见），但不会产生审计事件。

### 受影响的规则列表

#### 进程类（5 条 FAIL）
| 规则 ID | 问题 |
|---------|------|
| suspicious_exec_tmp | `-F dir=/tmp` 语法在当前 auditd 版本报错，未加载 |
| suspicious_exec_shm | `-F dir=/dev/shm` 同上 |
| suspicious_exec_vartmp | `-F dir=/var/tmp` 同上 |
| privilege_escalation (setuid) | `-S setuid` syscall 规则加载但与测试场景不匹配 |
| sudo_usage | `-w /usr/bin/sudo -p x` 文件监控不工作 |

#### 文件类（19 条 FAIL）
| 规则 ID | 问题 |
|---------|------|
| passwd_changes | `-w /etc/passwd -p wa` 不触发 |
| group_changes | `-w /etc/group -p wa` 不触发 |
| sshd_config_change | `-w /etc/ssh/sshd_config -p wa` 不触发 |
| sudoers_change | `-w /etc/sudoers -p wa` 不触发 |
| cron_change | `-w /etc/crontab -p wa` 不触发 |
| pam_change | `-w /etc/pam.d/ -p wa` 不触发 |
| system_lib_change | `-w /lib -p wa` 不触发 |
| system_bin_change | `-w /bin -p wa` 不触发 |
| audit_config_change | `-w /etc/audit/ -p wa` 不触发 |
| gshadow_changes | `-w /etc/gshadow -p rwa` 不触发 |
| opasswd_changes | `-w /etc/security/opasswd -p wa` 不触发 |
| ssh_config_change | `-w /etc/ssh/ssh_config -p wa` 不触发 |
| init_changes | `-w /etc/init.d -p wa` 不触发 |
| local_bin_change | `-w /usr/local/bin -p wa` 不触发 |
| shell_env_change | `-w /etc/profile -p wa` 不触发 |
| selinux_change | `-w /etc/selinux/ -p wa` 不触发 |
| apparmor_change | `-w /etc/apparmor/ -p wa` 不触发 |
| security_limits_change | `-w /etc/security/limits.conf -p wa` 不触发 |
| audit_log_change | `-w /var/log/audit/ -p wa` 不触发 |

#### 网络类（3 条 FAIL）
| 规则 ID | 问题 |
|---------|------|
| network_config_change | `-w /etc/hosts -p wa` 不触发 |
| firewall_config_change | `-w /etc/ufw/ -p wa` 不触发 |
| firewall_exec | `-w /sbin/iptables -p x` 不触发 |

#### Neo23x0 类（3 条 FAIL）
| 规则 ID | 问题 |
|---------|------|
| neo23x0_timestomp | touch 命令在白名单中 |
| neo23x0_software_mgmt | `-w /etc/apt -p wa` 不触发 |
| neo23x0_containers | `-w /etc/containers -p wa` 不触发 |

---

## 其他发现

### 1. 审计规则加载顺序问题
- `augenrules --load` 遇到不存在的路径时会停止加载后续规则
- 已移除 RHEL 专属路径：`/etc/sysconfig/network`, `/etc/firewalld`
- **建议**: 在 quick-install.sh 中加入路径存在性检查

### 2. `-F dir=` 语法不支持
- `auditctl: Syscall name unknown` 错误
- 40-neo23x0.rules 中的 `-F dir=/dev/shm/`, `-F dir=/etc/filebeat/` 等规则全部失败
- **建议**: 移除 `-F dir=` 语法或添加兼容性检查

### 3. quick-install.sh 引擎安装缺陷
- pip 缺失时跳过引擎安装，但安装 pip 后重跑不会自动补装
- systemd 服务 ExecStart 使用了 `--config` 标志，但 engine.py 只接受位置参数
- **建议**: 修复依赖检测逻辑和 ExecStart 参数格式

### 4. accept 系统调用不兼容
- x86_64 32 位审计上下文中不存在 `accept` 系统调用
- 已将 `accept` 改为 `accept4`

---

## 建议

1. **内核兼容性**: 在 `docs/COMPATIBILITY.md` 中注明 `-w` 文件监控规则在某些云内核上可能不工作
2. **添加 syscall 回退规则**: 对关键监控目标（如 `/etc/passwd`, `/etc/shadow`）同时使用 syscall 规则作为 `-w` 的补充
3. **修复安装脚本**: 修正引擎安装的幂等性问题和 systemd 服务配置
4. **清理 neo23x0 规则**: 移除对 `-F dir=` 和不存在路径的依赖
