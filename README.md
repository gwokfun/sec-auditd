# SEC-AUDITD

基于 Linux Auditd 的轻量级主机威胁感知与告警工具。

SEC-AUDITD 通过 auditd 采集系统事件，使用配置化规则监控进程、网络、文件和关键系统行为，并由 Python 告警引擎输出结构化告警日志。

## 功能概览

- 审计规则开箱即用，覆盖进程执行、网络连接、敏感文件、PAM、SSH、sudo、定时任务等场景
- 告警规则使用 YAML 管理，支持过滤器、白名单、限流和聚合告警
- 支持一键安装、标准安装、卸载和二进制部署
- 兼容 Python 3.x，另提供 Python 2.7、3.5、3.6 兼容引擎
- 支持 cgroups v1/v2 资源限制，缺失时可降级运行

## 环境要求

- Linux：CentOS/RHEL 7+、Ubuntu 18.04+、Debian 7+ 等
- Root 权限
- auditd
- Python 3.x 和 pip，或使用二进制引擎
- Python 依赖：见 [requirements.txt](requirements.txt)

多 Python 版本说明见 [docs/PYTHON_VERSIONS.md](docs/PYTHON_VERSIONS.md)，系统兼容性说明见 [docs/COMPATIBILITY.md](docs/COMPATIBILITY.md)。
完整安装、配置和运维步骤见 [docs/USER_GUIDE.md](docs/USER_GUIDE.md)。

## 快速安装

```bash
git clone https://github.com/gwokfun/sec-auditd.git
cd sec-auditd

# 推荐：自动安装依赖、规则、告警引擎并启动服务
sudo ./scripts/quick-install.sh --auto

# 最小化安装
sudo ./scripts/quick-install.sh --auto --minimal

# 指定 Python 版本
sudo ./scripts/quick-install.sh --auto -p 3.6

# 安装后不自动启动告警引擎
sudo ./scripts/quick-install.sh --auto --no-start
```

如目标系统已具备依赖，也可以使用标准安装脚本：

```bash
sudo ./scripts/install.sh
```

## 常用命令

```bash
# 查看服务状态
sudo systemctl status auditd
sudo systemctl status sec-auditd-alert

# 启停告警引擎
sudo systemctl start sec-auditd-alert
sudo systemctl restart sec-auditd-alert
sudo systemctl enable sec-auditd-alert

# 查看日志
sudo tail -f /var/log/audit/audit.log
sudo tail -f /var/log/sec-auditd/alert.log
sudo journalctl -u sec-auditd-alert -f

# 查询审计事件
sudo ausearch -ts recent -i
sudo ausearch -k process_exec -i
sudo ausearch -k network_connect -i

# 查看已加载规则
sudo auditctl -l
```

## 安装目录

安装后主要文件位于：

```text
/etc/sec-auditd/
├── audit.rules.d/          # auditd 规则
├── alert-engine/
│   ├── config.yaml         # 告警引擎配置
│   ├── engine.py           # 默认 Python 3 引擎
│   ├── py27/ py35/ py36/   # 兼容版本引擎
│   └── rules.d/            # YAML 告警规则
└── scripts/                # 运维脚本

/var/log/audit/audit.log        # auditd 原始日志
/var/log/sec-auditd/alert.log   # SEC-AUDITD 告警日志
```

## 配置规则

### Auditd 规则

编辑 `/etc/sec-auditd/audit.rules.d/` 后重新加载：

```bash
sudo sh -c 'cat /etc/sec-auditd/audit.rules.d/*.rules > /etc/audit/rules.d/sec-auditd.rules'
sudo augenrules --load
sudo auditctl -l
```

### 告警规则

在 `/etc/sec-auditd/alert-engine/rules.d/` 中添加或修改 YAML 文件：

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
    alert:
      message: "检测到可疑执行: {exe}"
      throttle: 300
```

修改后重启告警引擎：

```bash
sudo systemctl restart sec-auditd-alert
```

## 运维脚本

```bash
# 健康检查
sudo /etc/sec-auditd/scripts/check-audit.sh

# 测试规则
sudo /etc/sec-auditd/scripts/test-rules.sh

# 配置资源限制
sudo /etc/sec-auditd/scripts/setup-cgroups.sh

# 卸载，默认删除组件和日志
sudo ./scripts/uninstall.sh

# 卸载但保留日志
sudo ./scripts/uninstall.sh --keep-logs
```

## 二进制部署

```bash
# 构建独立引擎
sudo ./scripts/build-binary.sh

# 使用二进制引擎安装
sudo ./scripts/quick-install.sh --with-binary --auto
```

二进制文件建议在与目标系统架构和环境相近的机器上构建。

## 测试

```bash
pip3 install -r requirements.txt
python3 tests/test_engine.py

# 或使用 pytest
pip3 install pytest pytest-cov
pytest tests/
```

更多测试说明见 [tests/README.md](tests/README.md)。

## 日志采集

告警日志默认为 JSON 行格式，路径为 `/var/log/sec-auditd/alert.log`。可以通过 Filebeat、Fluent Bit、rsyslog 或现有 SIEM 采集；示例配置见 [examples/filebeat.yml](examples/filebeat.yml)。

## 文档

- [docs/USER_GUIDE.md](docs/USER_GUIDE.md)
- [CHANGELOG.md](CHANGELOG.md)
- [CONTRIBUTING.md](CONTRIBUTING.md)
- [docs/COMPATIBILITY.md](docs/COMPATIBILITY.md)
- [docs/cgroups-setup.md](docs/cgroups-setup.md)
- [docs/PYTHON_VERSIONS.md](docs/PYTHON_VERSIONS.md)
- [tests/README.md](tests/README.md)

## 许可证

MIT License
