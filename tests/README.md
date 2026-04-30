# SEC-AUDITD Tests

本目录包含 SEC-AUDITD 项目的单元测试和端到端测试。

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

# 只运行单元测试
pytest tests/test_engine.py tests/test_engine_extended.py

# 只运行端到端测试
pytest tests/test_engine_e2e.py

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

### 端到端测试（test_engine_e2e.py）
- ✅ 基本告警生成（进程执行事件 → 告警文件）
- ✅ 聚合告警（多事件累积触发阈值）
- ✅ 启动脚本默认版本启动
- ✅ 启动脚本版本选择功能
- ✅ 启动脚本帮助信息
- ✅ 启动脚本无效版本报错
- ✅ 多版本引擎兼容性（py35、py36、默认）
- ✅ SIGTERM 优雅退出
- ✅ SIGHUP 信号触发规则重新加载
- ✅ JSON 输出格式
- ✅ 文本（text）输出格式
- ✅ 白名单过滤（白名单进程不产生告警）
- ✅ 白名单过滤（非白名单进程正常告警）
- ✅ 过滤器表达式匹配事件
- ✅ 过滤器表达式不匹配时屏蔽事件
- ✅ 数值型 UID 过滤器
- ✅ 无 simpleeval 时 AST 回退求值

## CI/CD

项目使用 GitHub Actions 自动运行测试（`.github/workflows/ci.yml`）：
- 在每次 push 和 pull request 时触发
- 测试矩阵：Python 3.9、3.10、3.11、3.12
- 运行单元测试、扩展单元测试和端到端测试
- 运行 flake8 代码质量检查

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
```

## 注意事项

- 如果没有安装 `simpleeval`，测试仍然会通过，引擎会使用基于 AST 的安全回退求值
- 某些测试会创建临时文件和目录，测试完成后会自动清理
- 端到端测试会启动子进程运行引擎，每个测试约需 5-10 秒
- 单元测试应该在 1 秒内完成

## 添加新测试

在添加新功能时，请确保：

1. 为新功能添加相应的测试用例
2. 确保所有测试通过
3. 保持测试覆盖率不低于 70%

测试命名规范：
- 测试类: `Test<ComponentName>`
- 测试方法: `test_<feature_description>`
