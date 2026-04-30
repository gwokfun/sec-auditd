# 多 Python 版本支持文档

## 概述

SEC-AUDITD Alert Engine 现已支持多个 Python 版本，包括：
- Python 2.7
- Python 3.5
- Python 3.6
- Python 3.x（默认，3.7+）

## 目录结构

```
alert-engine/
├── engine.py              # 默认引擎（Python 3.x）
├── launch-engine.sh       # 启动脚本（支持版本选择）
├── config.yaml            # 配置文件
├── rules.d/               # 规则目录
├── py27/
│   └── engine.py          # Python 2.7 兼容版本
├── py35/
│   └── engine.py          # Python 3.5 兼容版本
└── py36/
    └── engine.py          # Python 3.6 兼容版本
```

## 使用方法

### 使用默认 Python 版本

```bash
# 直接运行引擎
python3 /etc/sec-auditd/alert-engine/engine.py /etc/sec-auditd/alert-engine/config.yaml

# 或使用启动脚本
/etc/sec-auditd/alert-engine/launch-engine.sh /etc/sec-auditd/alert-engine/config.yaml
```

### 指定 Python 版本

```bash
# 使用 Python 2.7
/etc/sec-auditd/alert-engine/launch-engine.sh --python-version 2.7 /etc/sec-auditd/alert-engine/config.yaml

# 使用 Python 3.5
/etc/sec-auditd/alert-engine/launch-engine.sh -p 3.5 /etc/sec-auditd/alert-engine/config.yaml

# 使用 Python 3.6
/etc/sec-auditd/alert-engine/launch-engine.sh -p 3.6 /etc/sec-auditd/alert-engine/config.yaml
```

### 查看帮助

```bash
/etc/sec-auditd/alert-engine/launch-engine.sh --help
```

## 版本差异说明

### Python 2.7 版本 (py27/engine.py)

**主要修改：**
- 移除所有类型注解（`:` 和 `->`）
- 使用 `from __future__ import` 导入 print_function 和 unicode_literals
- 将所有 `class ClassName:` 改为 `class ClassName(object):`
- 使用 `.format()` 替代 f-strings
- 使用 `str.decode('hex')` 替代 `bytes.fromhex()`
- 使用 `IOError` 替代 `FileNotFoundError`
- 使用 `datetime.utcnow()` 替代 `datetime.now(timezone.utc)`
- 支持 `unicode` 类型检查
- 使用旧式 AST 节点类型（`ast.Str`, `ast.Num`）

### Python 3.5 版本 (py35/engine.py)

**主要修改：**
- 保留类型注解
- 使用 `.format()` 替代 f-strings（Python 3.6+ 特性）
- 支持旧式和新式 AST 节点类型（兼容性）
- 使用 `datetime.now(timezone.utc)` 替代 UTC 时区

### Python 3.6 版本 (py36/engine.py)

**主要修改：**
- 与 Python 3.5 版本基本相同
- 使用 `.format()` 替代 f-strings
- 完全兼容 Python 3.6+

### 默认版本 (engine.py)

**特性：**
- 使用 f-strings（Python 3.6+）
- 使用现代类型注解
- 使用新式 AST 节点类型（`ast.Constant`）
- 支持所有最新的 Python 3 特性

## 兼容性矩阵

| 功能 | Python 2.7 | Python 3.5 | Python 3.6 | Python 3.x |
|------|-----------|-----------|-----------|-----------|
| 审计日志解析 | ✅ | ✅ | ✅ | ✅ |
| 规则匹配 | ✅ | ✅ | ✅ | ✅ |
| 安全表达式求值 | ✅ | ✅ | ✅ | ✅ |
| 聚合功能 | ✅ | ✅ | ✅ | ✅ |
| 白名单 | ✅ | ✅ | ✅ | ✅ |
| 告警限流 | ✅ | ✅ | ✅ | ✅ |
| 信号处理 | ✅ | ✅ | ✅ | ✅ |
| 类型注解 | ❌ | ✅ | ✅ | ✅ |
| f-strings | ❌ | ❌ | ❌ | ✅ |

## 测试

### 运行单元测试

```bash
# 测试默认引擎
python3 tests/test_engine.py
python3 tests/test_engine_extended.py

# 端到端测试（包括所有版本）
python3 tests/test_engine_e2e.py
```

### 测试覆盖

- 审计日志解析器测试
- 规则引擎测试
- 告警引擎测试
- 多版本兼容性测试
- 信号处理测试
- 端到端集成测试

## 部署建议

### 推荐配置

1. **生产环境**：使用默认 Python 3.x 版本
   - 性能最优
   - 特性最全
   - 维护最简单

2. **旧系统（CentOS 7, Ubuntu 16.04）**：使用 Python 2.7 或 3.5 版本
   - 系统兼容性好
   - 无需升级系统 Python

3. **中等系统（CentOS 8, Ubuntu 18.04）**：使用 Python 3.6 版本
   - 稳定可靠
   - 兼容性好

### systemd 服务配置

编辑 `/etc/systemd/system/sec-auditd-alert.service`：

```ini
[Unit]
Description=SEC-AUDITD Alert Engine
After=auditd.service

[Service]
Type=simple
# 使用默认版本
ExecStart=/etc/sec-auditd/alert-engine/launch-engine.sh /etc/sec-auditd/alert-engine/config.yaml

# 或指定 Python 版本
# ExecStart=/etc/sec-auditd/alert-engine/launch-engine.sh --python-version 2.7 /etc/sec-auditd/alert-engine/config.yaml

Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
```

## 常见问题

### Q: 如何确定系统应该使用哪个版本？

A: 运行以下命令检查系统 Python 版本：
```bash
python --version    # Python 2 版本
python3 --version   # Python 3 版本
```

然后选择最接近的版本：
- Python 2.6-2.7 → 使用 py27
- Python 3.4-3.5 → 使用 py35
- Python 3.6-3.7 → 使用 py36
- Python 3.8+ → 使用默认版本

### Q: 启动脚本会自动选择最佳版本吗？

A: 不会。启动脚本需要明确指定版本（使用 `--python-version`）或使用默认版本。这样设计是为了确保行为可预测。

### Q: 不同版本的性能有差异吗？

A: 有轻微差异。Python 3.x 通常比 Python 2.7 快 10-30%。但对于告警引擎这种 I/O 密集型应用，差异不明显。

### Q: 如何验证版本切换是否成功？

A: 查看引擎日志或进程信息：
```bash
# 查看进程
ps aux | grep engine.py

# 查看日志
journalctl -u sec-auditd-alert -f
```

## 技术细节

### 向后兼容性实现

1. **字符串格式化**
   - Python 2.7/3.5/3.6: `"message: {}".format(value)`
   - Python 3.x: `f"message: {value}"`

2. **十六进制解码**
   - Python 2.7: `value.decode('hex')`
   - Python 3.x: `bytes.fromhex(value).decode('utf-8')`

3. **时区处理**
   - Python 2.7: `datetime.utcnow().isoformat() + 'Z'`
   - Python 3.5+: `datetime.now(timezone.utc).isoformat()`

4. **AST 节点类型**
   - Python 2.7: 仅支持 `ast.Str`, `ast.Num`, `ast.Name`
   - Python 3.5-3.7: 支持新旧两种节点类型
   - Python 3.8+: 使用统一的 `ast.Constant`

### 安全性考虑

所有版本都实现了相同的安全机制：
- 使用 `simpleeval` 库进行安全表达式求值（如果可用）
- 回退到基于 AST 的安全实现
- 不使用 `eval()` 或 `exec()`
- 严格限制可执行的操作类型

## 维护指南

### 添加新功能时的注意事项

1. 首先在默认版本实现新功能
2. 确保不使用 Python 3.6+ 独有特性（除非必要）
3. 将功能向后移植到旧版本：
   - 移除 f-strings
   - 移除类型注解（Python 2.7）
   - 检查 API 兼容性
4. 更新所有版本的测试

### 版本同步

当修改核心逻辑时，需要同步更新所有版本：
- `engine.py` (默认)
- `py27/engine.py`
- `py35/engine.py`
- `py36/engine.py`

建议使用 diff 工具检查差异，确保逻辑一致性。

## 未来计划

- 添加 Python 3.7 和 3.8 的特定优化版本
- 提供自动版本检测和推荐
- 创建版本迁移指南
- 考虑使用二进制打包（PyInstaller）简化部署
