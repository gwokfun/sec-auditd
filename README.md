# SEC-AUDITD

基于 Linux Auditd 的本地主机威胁感知系统

## 项目简介

SEC-AUDITD 是一个轻量级的 Linux 主机威胁感知系统，通过 YAML 配置实现对系统活动的实时监控和告警，涵盖进程、网络、文件等核心维度。

**核心特性**：配置驱动、开箱即用、轻量高效、一键部署、支持二进制模式（无需 Python）、兼容 cgroups v1/v2。

## 快速开始

### 环境要求

- Linux (CentOS/RHEL 7+, Ubuntu 18.04+, Debian 7+)
- Auditd（通常系统自带）
- Python 3.6+（脚本模式）或使用二进制版本
- Root 权限

> 多 Python 版本支持（2.7, 3.5, 3.6, 3.x），详见 [Python 版本支持文档](docs/PYTHON_VERSIONS.md)。

### 安装

```bash
git clone https://github.com/gwokfun/sec-auditd.git
cd sec-auditd

# 一键自动安装（推荐）
sudo ./scripts/quick-install.sh --auto

# 指定 Python 版本
sudo ./scripts/quick-install.sh --auto -p 3.6

# 标准安装
sudo ./scripts/install.sh
```

### 启动服务

```bash
sudo systemctl start sec-auditd-alert
sudo systemctl enable sec-auditd-alert
sudo systemctl status sec-auditd-alert
```

### 查看日志

```bash
sudo tail -f /var/log/audit/audit.log
sudo tail -f /var/log/sec-auditd/alert.log
```

### 卸载

```bash
sudo ./scripts/uninstall.sh           # 卸载全部
sudo ./scripts/uninstall.sh --keep-logs  # 保留日志
```

## 配置说明

### 目录结构

```
/etc/sec-auditd/
├── audit.rules.d/      # Auditd 规则（00-base, 10-process, 20-network, 30-file, 99-finalize）
├── alert-engine/
│   ├── config.yaml     # 引擎配置
│   ├── rules.d/        # 告警规则（network.yaml, process.yaml, file.yaml）
│   └── engine.py
└── scripts/            # check-audit.sh, test-rules.sh
```

### 自定义告警规则

在 `/etc/sec-auditd/alert-engine/rules.d/` 下创建 YAML 文件：

```yaml
rules:
  - id: my_custom_rule
    name: "自定义告警规则"
    enabled: true
    severity: high
    match:
      key: "process_exec"
      filters:
        - "'/tmp' in exe"
    whitelist:
      - process: "apt-get"
    alert:
      message: "检测到可疑执行: {exe}"
      throttle: 300
```

修改后重启服务：`sudo systemctl restart sec-auditd-alert`

## 二进制部署（可选）

```bash
# 构建二进制（无需 Python 依赖）
sudo ./scripts/build-binary.sh

# 使用二进制安装
sudo ./scripts/quick-install.sh --with-binary --auto
```

## 故障排查

```bash
# Auditd 规则未生效
sudo auditctl -l
sudo auditctl -R /etc/audit/rules.d/sec-auditd.rules

# 告警引擎问题
sudo systemctl status sec-auditd-alert
sudo journalctl -u sec-auditd-alert -f

# 检查配置语法
sudo python3 -c "import yaml, sys; yaml.safe_load(open(sys.argv[1]))" /etc/sec-auditd/alert-engine/config.yaml
```

## SIEM 集成

通过 Filebeat 将 `/var/log/audit/audit.log` 和 `/var/log/sec-auditd/alert.log` 发送到 Elasticsearch/Logstash。

## 贡献

欢迎提交 Issue 和 Pull Request！详见 [CONTRIBUTING.md](CONTRIBUTING.md)。

## 变更日志

详见 [CHANGELOG.md](CHANGELOG.md)

## 许可证

MIT License — [gwokfun](https://github.com/gwokfun)
