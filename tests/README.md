# SEC-AUDITD Tests

本目录包含 SEC-AUDITD 项目的单元测试。

## 运行测试

### 基本测试

```bash
python3 tests/test_engine.py
```

### 使用 pytest（推荐）

```bash
# 安装 pytest
pip3 install pytest pytest-cov

# 运行测试
pytest tests/

# 运行测试并生成覆盖率报告
pytest tests/ --cov=alert-engine --cov-report=html
```

## 测试覆盖

当前测试包括：

### AuditParser 测试
- ✅ 解析简单的审计日志行
- ✅ 解析空行和无效行
- ✅ 解码十六进制编码的值
- ✅ 事件丰富（添加时间戳、转换UID等）

### RuleEngine 测试
- ✅ 加载配置文件
- ✅ 加载规则文件
- ✅ 规则匹配逻辑
- ✅ 白名单过滤
- ✅ 安全的过滤器求值
- ✅ 告警生成
- ✅ 告警限流

## 依赖

测试需要以下 Python 包：

```
PyYAML>=5.1,<7.0
simpleeval>=0.9.13  # 可选，用于安全的表达式求值
pytest>=7.0.0  # 可选，用于更好的测试运行器
pytest-cov>=4.0.0  # 可选，用于代码覆盖率
```

安装所有依赖：

```bash
pip3 install -r requirements.txt
pip3 install pytest pytest-cov
```

## 注意事项

- 如果没有安装 `simpleeval`，测试仍然会通过，但会使用回退的表达式求值方法
- 某些测试会创建临时文件和目录，测试完成后会自动清理
- 所有测试应该在 1 秒内完成

## 添加新测试

在添加新功能时，请确保：

1. 为新功能添加相应的测试用例
2. 确保所有测试通过
3. 保持测试覆盖率不低于 80%

测试命名规范：
- 测试类: `Test<ComponentName>`
- 测试方法: `test_<feature_description>`
