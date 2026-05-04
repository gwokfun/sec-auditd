# SEC-AUDITD 指引手册

本文档面向安装、配置和日常运维人员，补充 README 中被精简掉的详细说明。初次了解项目请先阅读 [README.md](../README.md)。

## 工作方式

SEC-AUDITD 由三部分组成：

1. auditd 规则：定义系统需要采集哪些事件，例如进程执行、网络连接、敏感文件访问。
2. auditd 服务：将匹配到的事件写入 `/var/log/audit/audit.log`。
3. 告警引擎：读取 auditd 日志，根据 YAML 告警规则生成 `/var/log/sec-auditd/alert.log`。

典型数据流：

```text
audit.rules.d/*.rules
    -> auditd
    -> /var/log/audit/audit.log
    -> alert-engine
    -> /var/log/sec-auditd/alert.log
```

## 监控范围

默认规则主要覆盖以下行为：

- 进程：进程创建、临时目录执行、sudo/su 使用、特权提升、内核模块加载
- 网络：连接建立、端口监听、连接接受、网络配置和防火墙变更
- 文件：账号认证文件、SSH 配置和密钥、sudo 配置、PAM、定时任务、系统服务、关键二进制和库文件
- 异常：高频进程执行、短时间大量连接、临时目录程序网络连接、敏感文件访问
- Neo23x0 规则：权限修改、未授权文件访问、匿名文件创建、bpf、namespace、进程注入等审计键

## 安装

### 环境要求

- Linux 系统，推荐使用 systemd 管理服务
- root 权限
- auditd
- Python 3.x 和 pip，或使用二进制引擎
- Python 依赖见 [requirements.txt](../requirements.txt)

兼容性细节见 [COMPATIBILITY.md](COMPATIBILITY.md)，多 Python 版本说明见 [PYTHON_VERSIONS.md](PYTHON_VERSIONS.md)。

### 快速安装

快速安装脚本会自动检测包管理器，安装缺失依赖，部署规则、告警引擎、日志轮转和资源限制，并启动服务。

```bash
git clone https://github.com/gwokfun/sec-auditd.git
cd sec-auditd
sudo ./scripts/quick-install.sh --auto
```

常用参数：

```bash
# 最小化安装，不配置 cgroups 资源限制
sudo ./scripts/quick-install.sh --auto --minimal

# 安装后不启动告警引擎
sudo ./scripts/quick-install.sh --auto --no-start

# 使用兼容 Python 版本
sudo ./scripts/quick-install.sh --auto -p 3.5
sudo ./scripts/quick-install.sh --auto -p 3.6

# 使用二进制引擎
sudo ./scripts/quick-install.sh --auto --with-binary
```

### 标准安装

当系统依赖已经准备好，或需要更传统的交互式安装流程时使用：

```bash
sudo ./scripts/install.sh
```

指定 Python 版本：

```bash
sudo ./scripts/install.sh -p 3.6
```

### 二进制部署

目标系统没有合适 Python 环境时，可以先构建独立引擎：

```bash
sudo ./scripts/build-binary.sh
sudo ./scripts/quick-install.sh --with-binary --auto
```

二进制文件与系统架构相关，建议在与目标环境相近的系统上构建。

## 安装后的目录

```text
/etc/sec-auditd/
├── audit.rules.d/              # auditd 规则源文件
│   ├── 00-base.rules
│   ├── 10-process.rules
│   ├── 20-network.rules
│   ├── 30-file.rules
│   ├── 40-neo23x0.rules
│   └── 99-finalize.rules
├── alert-engine/
│   ├── config.yaml             # 告警引擎配置
│   ├── engine.py               # 默认 Python 3 引擎
│   ├── py27/ py35/ py36/       # 兼容版本引擎
│   └── rules.d/                # YAML 告警规则
└── scripts/                    # check/test/cgroups 等运维脚本

/etc/audit/rules.d/sec-auditd.rules
/etc/logrotate.d/sec-auditd
/var/log/audit/audit.log
/var/log/sec-auditd/alert.log
```

## 服务管理

```bash
# auditd
sudo systemctl status auditd
sudo systemctl restart auditd

# 告警引擎
sudo systemctl status sec-auditd-alert
sudo systemctl start sec-auditd-alert
sudo systemctl restart sec-auditd-alert
sudo systemctl enable sec-auditd-alert

# 告警引擎运行日志
sudo journalctl -u sec-auditd-alert -f
```

## Auditd 规则管理

### 查看规则

```bash
sudo auditctl -l
sudo auditctl -s
```

### 修改规则

编辑 `/etc/sec-auditd/audit.rules.d/` 中的规则文件。规则文件按名称顺序合并，建议保留数字前缀来控制加载顺序。

修改后重新生成并加载：

```bash
sudo sh -c 'cat /etc/sec-auditd/audit.rules.d/*.rules > /etc/audit/rules.d/sec-auditd.rules'
sudo augenrules --load
sudo auditctl -l
```

如果 `augenrules` 加载失败，可以尝试直接加载：

```bash
sudo auditctl -R /etc/audit/rules.d/sec-auditd.rules
```

### 查询事件

```bash
# 最近事件
sudo ausearch -ts recent -i

# 指定 key
sudo ausearch -k process_exec -i
sudo ausearch -k network_connect -i
sudo ausearch -k passwd_changes -i

# 时间范围
sudo ausearch -ts today -i
sudo ausearch -ts 10:00 -te 11:00 -i

# 用户或报表
sudo ausearch -ua username -i
sudo aureport --summary
sudo aureport --executable
```

## 告警引擎配置

默认配置文件为 `/etc/sec-auditd/alert-engine/config.yaml`。

常见配置项：

```yaml
engine:
  input:
    type: file
    file: /var/log/audit/audit.log
  output:
    - type: file
      path: /var/log/sec-auditd/alert.log
      format: json
    - type: syslog
      enabled: false
      facility: local0
      severity: warning
  rules:
    dir: /etc/sec-auditd/alert-engine/rules.d/
    reload_interval: 60
```

修改配置后重启服务：

```bash
sudo systemctl restart sec-auditd-alert
```

## 告警规则管理

告警规则位于 `/etc/sec-auditd/alert-engine/rules.d/`，使用 YAML 编写。

### 基本规则

```yaml
rules:
  - id: suspicious_tmp_exec
    name: "临时目录可疑执行"
    enabled: true
    severity: high
    match:
      key: "process_exec"
      filters:
        - "'/tmp' in exe or '/dev/shm' in exe"
    whitelist:
      - process: "apt-get"
    alert:
      message: "检测到可疑执行: {exe} (PID: {pid}, UID: {uid})"
      throttle: 300
```

字段说明：

- `id`：规则唯一标识
- `name`：规则名称
- `enabled`：是否启用
- `severity`：告警级别，支持 `low`、`medium`、`high`、`critical`
- `match.key`：匹配 auditd 事件中的 `key`
- `match.filters`：过滤表达式，表达式为真时才告警
- `whitelist`：白名单，匹配后不告警
- `alert.message`：告警内容模板，可引用事件字段
- `alert.throttle`：限流秒数

### 聚合规则

聚合规则适合发现短时间内重复出现的行为：

```yaml
rules:
  - id: process_burst
    name: "短时间大量进程执行"
    enabled: true
    severity: high
    match:
      key: "process_creation"
    aggregate:
      window: 60
      group_by: ["uid"]
      count: 50
    alert:
      message: "UID {uid} 在60秒内执行了 {count} 次进程"
      throttle: 300
```

修改规则后通常会在 `reload_interval` 周期内自动加载。需要立即生效时可重启服务：

```bash
sudo systemctl restart sec-auditd-alert
```

## 日志和日志轮转

主要日志：

```bash
sudo tail -f /var/log/audit/audit.log
sudo tail -f /var/log/sec-auditd/alert.log
sudo journalctl -u sec-auditd-alert -f
```

日志轮转配置位于 `/etc/logrotate.d/sec-auditd`。手动触发：

```bash
sudo logrotate -f /etc/logrotate.d/sec-auditd
```

查看日志大小：

```bash
sudo du -sh /var/log/audit/
sudo du -sh /var/log/sec-auditd/
```

## 资源限制

快速安装默认会配置告警引擎资源限制。也可以手动执行：

```bash
sudo /etc/sec-auditd/scripts/setup-cgroups.sh
```

脚本会自动识别 cgroups v1、v2 或无 cgroups 环境，并尽量使用 systemd 限制 CPU、内存和任务数。详细说明见 [cgroups-setup.md](cgroups-setup.md)。

## 日志采集和 SIEM 集成

告警日志默认为 JSON 行格式，适合被 Filebeat、Fluent Bit、rsyslog、Logstash 或其他 SIEM 采集。

Filebeat 示例见 [examples/filebeat.yml](../examples/filebeat.yml)。常见采集目标：

- `/var/log/audit/audit.log`：原始 auditd 事件
- `/var/log/sec-auditd/alert.log`：SEC-AUDITD 告警事件

## 测试和验证

安装后可运行：

```bash
sudo /etc/sec-auditd/scripts/check-audit.sh
sudo /etc/sec-auditd/scripts/test-rules.sh
```

开发环境测试：

```bash
pip3 install -r requirements.txt
python3 tests/test_engine.py
pytest tests/
```

完整测试说明见 [tests/README.md](../tests/README.md)。

## 性能调优

如果日志量或系统负载过高，优先考虑：

1. 注释掉不需要的 auditd 规则，减少采集面。
2. 对高频规则设置更长的 `throttle`。
3. 为已知合法进程添加白名单。
4. 使用聚合规则代替逐条高频告警。
5. 查看 `sudo auditctl -s`，关注 backlog 和 lost 事件。
6. 根据负载调整 `00-base.rules` 中的缓冲区参数。

## 故障排查

### 看不到 auditd 日志

```bash
sudo systemctl status auditd
sudo auditctl -l
sudo tail -f /var/log/audit/audit.log
```

确认 auditd 正在运行，规则已经加载，并且触发了对应系统行为。

### 告警引擎没有告警

```bash
sudo systemctl status sec-auditd-alert
sudo journalctl -u sec-auditd-alert -f
sudo tail -f /var/log/sec-auditd/alert.log
```

检查告警规则中的 `match.key` 是否与 auditd 事件中的 `key` 一致。

### 配置文件语法错误

```bash
sudo python3 -c "import yaml, sys; yaml.safe_load(open(sys.argv[1]))" /etc/sec-auditd/alert-engine/config.yaml
```

也可以对新写的规则文件执行同类 YAML 解析检查。

### 日志占用空间过大

```bash
sudo du -sh /var/log/audit/*
sudo du -sh /var/log/sec-auditd/*
sudo logrotate -f /etc/logrotate.d/sec-auditd
```

必要时调整 `/etc/audit/auditd.conf` 中的日志大小和保留策略。

## 升级

升级前建议备份配置：

```bash
sudo cp -r /etc/sec-auditd /etc/sec-auditd.backup
```

更新代码并重新安装：

```bash
cd sec-auditd
git pull
sudo ./scripts/quick-install.sh --auto
```

如果有自定义规则，确认它们仍在 `/etc/sec-auditd/audit.rules.d/` 和 `/etc/sec-auditd/alert-engine/rules.d/` 中。

## 卸载

```bash
# 删除组件和日志
sudo ./scripts/uninstall.sh

# 保留日志
sudo ./scripts/uninstall.sh --keep-logs
```

## 安全建议

- 定期审查启用的 auditd 规则和告警规则
- 为业务系统的正常高频行为添加明确白名单
- 保护 `/etc/sec-auditd/`，只允许 root 修改
- 将告警日志接入集中日志或 SIEM，避免只保存在本机
- 备份自定义规则和配置
- 定期验证告警链路是否仍能产生预期告警
