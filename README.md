# SEC-AUDITD

基于 Linux Auditd 的本地主机威胁感知系统

## 项目简介

SEC-AUDITD 是一个轻量级的 Linux 主机威胁感知系统，通过配置化的方式实现对系统活动的实时监控和告警。

### 核心特性

- ✅ **配置驱动**：规则和策略通过 YAML 配置，无需编程
- ✅ **轻量高效**：基于系统自带的 auditd，性能开销最小
- ✅ **开箱即用**：提供完整的审计规则和告警规则
- ✅ **灵活扩展**：易于添加自定义规则和集成外部系统
- ✅ **低维护成本**：Shell/Python 实现，便于运维管理
- ✅ **一键部署**：支持全自动安装，无需手动配置
- ✅ **广泛兼容**：支持 cgroups v1/v2，兼容旧版 Linux 系统
- ✅ **二进制部署**：可选二进制打包，无需 Python 依赖

### 监控能力

#### 进程监控
- 所有进程执行
- 临时目录可疑执行 (/tmp, /dev/shm, /var/tmp)
- 特权提升操作 (setuid/setgid)
- sudo/su 使用
- 内核模块加载

#### 网络监控
- 网络连接建立 (connect)
- 端口监听 (bind/listen)
- 连接接受 (accept)
- 网络配置变更
- 防火墙规则变更

#### 文件监控
- 用户认证文件 (/etc/passwd, /etc/shadow)
- SSH 配置和密钥
- Sudo 配置
- 系统服务和启动项
- 定时任务 (crontab)
- 系统库和二进制文件
- PAM 配置

#### 异常检测
- 临时目录程序网络连接
- 短时间大量连接
- 高频进程执行
- 敏感文件访问

## 系统架构

```
┌─────────────────────────────────────────────────┐
│                 SEC-AUDITD 架构                  │
├─────────────────────────────────────────────────┤
│                                                  │
│  ┌──────────────┐                               │
│  │   Auditd     │  配置规则采集事件              │
│  │   Rules      │                               │
│  └──────┬───────┘                               │
│         │                                        │
│         ▼                                        │
│  ┌──────────────┐                               │
│  │   Auditd     │  审计日志                      │
│  │   Daemon     │  /var/log/audit/audit.log     │
│  └──────┬───────┘                               │
│         │                                        │
│         ├────────────────┐                      │
│         │                │                      │
│         ▼                ▼                      │
│  ┌──────────┐    ┌─────────────┐               │
│  │ Logrotate│    │  告警引擎    │               │
│  │  日志轮转 │    │  (Python)   │               │
│  └──────────┘    └──────┬──────┘               │
│                         │                       │
│                         ▼                       │
│                  ┌──────────────┐               │
│                  │  告警日志     │               │
│                  │  alert.log   │               │
│                  └──────────────┘               │
│                                                  │
│  ┌─────────────────────────────┐               │
│  │      Filebeat (可选)         │               │
│  │  采集日志上传到 SIEM         │               │
│  └─────────────────────────────┘               │
│                                                  │
└─────────────────────────────────────────────────┘
```

## 快速开始

### 环境要求

- Linux 操作系统 (CentOS/RHEL 7+, Ubuntu 18.04+, Debian 7+)
  - 支持 cgroups v1 和 v2
  - 不支持 cgroups 的系统可使用基本进程控制
- Auditd (通常系统自带)
- Python（脚本模式）
  - **推荐**: Python 3.6+ （默认版本）
  - **兼容**: Python 2.7, 3.5, 3.6（版本特定实现）
  - 或使用二进制版本（无需 Python）
- Python 依赖包（脚本模式）：
  - PyYAML >= 5.1
  - simpleeval >= 0.9.13 (可选，用于增强的表达式求值)
- Root 权限

**多 Python 版本支持**: SEC-AUDITD 现已支持多个 Python 版本，包括 Python 2.7、3.5、3.6 和 3.x（默认）。详见 [Python 版本支持文档](docs/PYTHON_VERSIONS.md)。

### 快速安装（推荐）

**方式 1：一键自动安装**

```bash
# 克隆仓库
git clone https://github.com/gwokfun/sec-auditd.git
cd sec-auditd

# 全自动安装（推荐）
sudo ./scripts/quick-install.sh --auto

# 或最小化安装
sudo ./scripts/quick-install.sh --auto --minimal
```

**方式 2：在线安装（开发中）**

```bash
# 使用 curl
curl -fsSL https://raw.githubusercontent.com/gwokfun/sec-auditd/main/scripts/quick-install.sh | sudo bash

# 或使用 wget
wget -qO- https://raw.githubusercontent.com/gwokfun/sec-auditd/main/scripts/quick-install.sh | sudo bash
```

quick-install.sh 特性：
- ✅ 自动检测并安装缺少的依赖（auditd, python3, pip）
- ✅ 支持多种包管理器（apt, yum, dnf, zypper）
- ✅ 自动配置 cgroups 资源限制（支持 v1/v2）
- ✅ 一键启动所有服务
- ✅ 支持命令行参数定制安装

### 标准安装步骤

1. **克隆仓库**

```bash
git clone https://github.com/gwokfun/sec-auditd.git
cd sec-auditd
```

2. **运行安装脚本**

```bash
sudo ./scripts/install.sh
```

安装脚本会自动：
- 检查依赖
- 安装 Python 依赖包（PyYAML, simpleeval）
- 部署 auditd 规则
- 配置日志轮转
- 安装告警引擎
- 创建 systemd 服务

3. **启动告警引擎**（可选）

```bash
# 启动服务
sudo systemctl start sec-auditd-alert

# 设置开机启动
sudo systemctl enable sec-auditd-alert

# 查看状态
sudo systemctl status sec-auditd-alert
```

4. **查看日志**

```bash
# 查看审计日志
sudo tail -f /var/log/audit/audit.log

# 查看告警日志
sudo tail -f /var/log/sec-auditd/alert.log

# 使用 ausearch 查询特定事件
sudo ausearch -k process_exec -i
sudo ausearch -k network_connect -i
```

### 二进制部署（可选）

如果目标系统没有 Python 或希望简化部署，可以使用二进制版本：

**1. 构建二进制文件**

```bash
# 在开发机上构建
cd sec-auditd
sudo ./scripts/build-binary.sh
```

这将使用 PyInstaller 将 engine.py 打包为独立的二进制文件（约 30-50MB）。

**2. 使用二进制安装**

```bash
# 复制二进制文件到目标系统后
sudo ./scripts/quick-install.sh --with-binary --auto
```

**注意事项：**
- 二进制文件仅适用于相同的 Linux 架构（x86_64/ARM64）
- 建议在与目标系统相似的环境中构建
- 配置文件和规则文件仍需单独部署

### 卸载

```bash
# 卸载所有组件（包括日志）
sudo ./scripts/uninstall.sh

# 卸载但保留日志文件
sudo ./scripts/uninstall.sh --keep-logs
```

## 配置说明

### 目录结构

```
/etc/sec-auditd/
├── audit.rules.d/              # Auditd 规则配置
│   ├── 00-base.rules           # 基础规则
│   ├── 10-process.rules        # 进程监控规则
│   ├── 20-network.rules        # 网络监控规则
│   ├── 30-file.rules           # 文件监控规则
│   └── 99-finalize.rules       # 最终规则
├── alert-engine/               # 告警引擎
│   ├── config.yaml             # 引擎配置
│   ├── rules.d/                # 告警规则
│   │   ├── network.yaml
│   │   ├── process.yaml
│   │   └── file.yaml
│   └── engine.py               # 引擎程序
└── scripts/                    # 辅助脚本
    ├── install.sh
    ├── check-audit.sh
    └── test-rules.sh
```

### 自定义 Auditd 规则

编辑 `/etc/sec-auditd/audit.rules.d/` 下的规则文件，然后重新加载：

```bash
# 生成规则文件
sudo cat /etc/sec-auditd/audit.rules.d/*.rules > /etc/audit/rules.d/sec-auditd.rules

# 重新加载规则
sudo augenrules --load
# 或
sudo auditctl -R /etc/audit/rules.d/sec-auditd.rules

# 查看已加载的规则
sudo auditctl -l
```

### 自定义告警规则

编辑 `/etc/sec-auditd/alert-engine/rules.d/` 下的 YAML 文件。

告警规则示例：

```yaml
rules:
  - id: my_custom_rule
    name: "自定义告警规则"
    enabled: true
    severity: high

    match:
      key: "process_exec"  # 匹配 auditd 规则的 key
      filters:
        - "'/tmp' in exe"  # Python 表达式过滤

    whitelist:
      - process: "apt-get"  # 白名单

    alert:
      message: "检测到可疑执行: {exe}"
      throttle: 300  # 5分钟限流
```

修改后重启告警引擎：

```bash
sudo systemctl restart sec-auditd-alert
```

## 管理和运维

### 查看系统状态

```bash
# 运行状态检查脚本
sudo /etc/sec-auditd/scripts/check-audit.sh
```

### 测试规则

```bash
# 运行规则测试脚本
sudo /etc/sec-auditd/scripts/test-rules.sh
```

### 查询审计事件

```bash
# 查询最近的事件
sudo ausearch -ts recent -i

# 查询特定 key 的事件
sudo ausearch -k process_exec -i
sudo ausearch -k network_connect -i
sudo ausearch -k passwd_changes -i

# 查询特定时间范围
sudo ausearch -ts today -i
sudo ausearch -ts 10:00 -te 11:00 -i

# 查询特定用户的操作
sudo ausearch -ua username -i

# 生成审计报告
sudo aureport --summary
sudo aureport --executable
```

### 日志管理

日志会自动轮转，配置文件位于 `/etc/logrotate.d/sec-auditd`

```bash
# 手动触发日志轮转
sudo logrotate -f /etc/logrotate.d/sec-auditd

# 查看日志大小
sudo du -sh /var/log/audit/
sudo du -sh /var/log/sec-auditd/
```

### 性能调优

如果系统负载较高，可以考虑：

1. **减少监控范围**：注释掉不需要的规则
2. **添加白名单**：在告警规则中添加已知进程
3. **调整日志级别**：修改 `/etc/audit/auditd.conf`
4. **增加缓冲区**：在 `00-base.rules` 中增加 `-b` 参数值

```bash
# 查看当前丢失的事件数
sudo auditctl -s
```

### 资源限制配置

SEC-AUDITD 支持使用 cgroups 限制告警引擎的资源使用：

```bash
# 配置资源限制（CPU ~5%, 内存 ~5%）
sudo /etc/sec-auditd/scripts/setup-cgroups.sh
```

**兼容性说明：**
- ✅ **cgroups v2**：完整支持（Linux 4.5+, systemd 232+）
  - Debian 10+, Ubuntu 20.04+, CentOS 8+
  - 支持 CPU、内存、I/O 限制
- ✅ **cgroups v1**：兼容支持（Linux 2.6.24+）
  - Debian 7-9, Ubuntu 16.04-18.04, CentOS 7
  - 支持 CPU、内存限制
- ✅ **无 cgroups**：优雅降级
  - 使用 Nice、TasksMax、OOMScoreAdjust 等基本控制
  - 适用于旧版系统

脚本会自动检测系统支持的 cgroups 版本并生成相应配置。

## Filebeat 集成

### 配置示例

创建 `/etc/filebeat/filebeat.yml`：

```yaml
filebeat.inputs:
  # Auditd 日志
  - type: log
    enabled: true
    paths:
      - /var/log/audit/audit.log
    fields:
      log_type: auditd
      source: sec-auditd
    fields_under_root: true

  # 告警日志
  - type: log
    enabled: true
    paths:
      - /var/log/sec-auditd/alert.log
    fields:
      log_type: alert
      source: sec-auditd
    fields_under_root: true
    json.keys_under_root: true
    json.add_error_key: true

# 输出到 Elasticsearch
output.elasticsearch:
  hosts: ["your-elasticsearch:9200"]
  index: "sec-auditd-%{+yyyy.MM.dd}"

# 或输出到 Logstash
# output.logstash:
#   hosts: ["your-logstash:5044"]
```

### 启动 Filebeat

```bash
sudo systemctl start filebeat
sudo systemctl enable filebeat
```

## 故障排查

### Auditd 规则未生效

```bash
# 检查 auditd 服务状态
sudo systemctl status auditd

# 查看规则加载情况
sudo auditctl -l

# 查看 auditd 日志
sudo tail -f /var/log/audit/audit.log

# 重新加载规则
sudo auditctl -R /etc/audit/rules.d/sec-auditd.rules
```

### 告警引擎未产生告警

```bash
# 查看告警引擎状态
sudo systemctl status sec-auditd-alert

# 查看告警引擎日志
sudo journalctl -u sec-auditd-alert -f

# 检查配置文件语法
sudo python3 -c "import yaml, sys; yaml.safe_load(open(sys.argv[1]))" /etc/sec-auditd/alert-engine/config.yaml

# 手动运行测试
sudo python3 /etc/sec-auditd/alert-engine/engine.py \
  /etc/sec-auditd/alert-engine/config.yaml
```

### 日志占用空间过大

```bash
# 查看日志大小
sudo du -sh /var/log/audit/*

# 手动清理旧日志
sudo find /var/log/audit/ -name "*.gz" -mtime +30 -delete

# 调整 auditd 配置
sudo vim /etc/audit/auditd.conf
# 修改: max_log_file = 50 (单位 MB)
```

## 安全建议

1. **定期审查规则**：根据业务需求调整监控范围
2. **监控审计系统自身**：已包含在 `99-finalize.rules` 中
3. **及时处理告警**：建立告警响应流程
4. **备份配置**：定期备份 `/etc/sec-auditd/` 目录
5. **限制访问权限**：确保配置文件只有 root 可以修改

## 常见问题

**Q: 为什么看不到审计日志？**

A: 确保 auditd 服务正在运行：`sudo systemctl status auditd`

**Q: 规则太多会影响性能吗？**

A: Auditd 性能开销很小，但建议根据实际需求调整规则，避免监控不必要的事件。

**Q: 如何添加自定义告警规则？**

A: 在 `/etc/sec-auditd/alert-engine/rules.d/` 目录下创建新的 YAML 文件，参考现有规则格式。

**Q: 能否集成到现有的 SIEM 系统？**

A: 可以，通过 filebeat 将日志发送到 Elasticsearch/Logstash，或通过 syslog 集成。

**Q: 告警太多怎么办？**

A: 调整告警规则的 `throttle` 参数，增加白名单，或禁用不需要的规则。

## 贡献

欢迎提交 Issue 和 Pull Request！

请参阅 [CONTRIBUTING.md](CONTRIBUTING.md) 了解如何贡献代码。

## 变更日志

详见 [CHANGELOG.md](CHANGELOG.md)

## 许可证

MIT License

## 作者

gwokfun

## 相关资源

- [Auditd 官方文档](https://access.redhat.com/documentation/en-us/red_hat_enterprise_linux/7/html/security_guide/chap-system_auditing)
- [Audit 规则示例](https://github.com/Neo23x0/auditd)
- [Linux 审计最佳实践](https://www.cisecurity.org/)
