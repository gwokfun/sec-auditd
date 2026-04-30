# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- 单元测试框架 (tests/test_engine.py)
- requirements.txt 依赖管理
- CONTRIBUTING.md 贡献指南
- CHANGELOG.md 变更日志
- **快速安装脚本** (scripts/quick-install.sh)
  - 支持全自动安装（--auto 参数）
  - 自动检测并安装系统依赖（auditd, python3, pip）
  - 支持多种包管理器（apt, yum, dnf, zypper）
  - 支持最小化安装模式（--minimal）
  - 支持二进制部署模式（--with-binary）
- **二进制打包脚本** (scripts/build-binary.sh)
  - 使用 PyInstaller 打包 engine.py 为独立二进制文件
  - 无需 Python 环境即可运行
  - 支持跨发行版部署
- **卸载脚本** (scripts/uninstall.sh)
  - 完整卸载所有组件和配置
  - 可选保留日志文件（--keep-logs）
- **cgroups v1/v2 兼容性支持**
  - 自动检测系统 cgroups 版本
  - 支持 cgroups v1（Debian 7+, CentOS 7, Ubuntu 16.04+）
  - 支持 cgroups v2（Debian 10+, Ubuntu 20.04+, CentOS 8+）
  - 不支持 cgroups 时优雅降级（使用 Nice、TasksMax 等）

### Changed
- **[安全]** 替换 eval() 为 simpleeval 库，提高表达式求值安全性
- **[安全]** 改进异常处理，使用具体的异常类型而非裸 except
- 文件编码错误处理从 'ignore' 改为 'replace'
- 增加日志轮询间隔从 0.1 秒到 0.5 秒，降低 CPU 占用
- 改进错误日志，包含更多上下文信息
- 优化配置和规则加载的错误处理
- 更新安装脚本以使用 requirements.txt
- **改进 setup-cgroups.sh**
  - 支持 cgroups v1 和 v2 自动检测
  - 根据版本生成相应的 systemd 配置
  - 不支持 cgroups 时提供基本进程控制
- **扩展环境支持**
  - 从 Debian 10+ 扩展到 Debian 7+
  - 增加对旧版 CentOS 7、Ubuntu 16.04 的支持

### Fixed
- 修复 decode_audit_value 中的异常处理
- 修复 enrich_event 中的类型转换异常
- 改进消息格式化的错误处理

## [0.1.0] - 2026-04-30

### Added
- 基于 Linux Auditd 的主机威胁感知系统
- 进程执行监控
- 网络连接监控
- 敏感文件监控
- Python 告警引擎
- 告警规则系统
- 告警限流机制
- 白名单支持
- 事件聚合功能
- 完整的安装脚本
- 系统状态检查脚本
- 规则测试脚本
- 详细的中文文档

[Unreleased]: https://github.com/gwokfun/sec-auditd/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/gwokfun/sec-auditd/releases/tag/v0.1.0
