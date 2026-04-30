# Contributing to SEC-AUDITD

感谢您考虑为 SEC-AUDITD 做出贡献！

## 如何贡献

### 报告 Bug

如果您发现了 bug，请在 GitHub Issues 中创建一个新的 issue，并包含以下信息：

- 清晰的标题和描述
- 重现步骤
- 预期行为和实际行为
- 系统环境（操作系统、版本等）
- 相关日志或错误信息

### 提交功能请求

如果您有新功能的想法，请先在 Issues 中讨论：

- 描述功能的用途和价值
- 提供使用场景
- 如果可能，提供实现思路

### 提交代码

#### 开发环境设置

1. Fork 本仓库
2. 克隆您的 fork：
   ```bash
   git clone https://github.com/YOUR_USERNAME/sec-auditd.git
   cd sec-auditd
   ```

3. 安装开发依赖：
   ```bash
   pip3 install -r requirements.txt
   pip3 install pytest pytest-cov black flake8
   ```

#### 代码规范

- **Python 代码**：遵循 PEP 8 规范
  - 使用 4 个空格缩进
  - 最大行长度 120 字符
  - 使用 black 格式化代码：`black alert-engine/`
  - 使用 flake8 检查代码：`flake8 alert-engine/`

- **Shell 脚本**：
  - 使用 2 个空格缩进
  - 使用有意义的变量名
  - 添加必要的注释

- **YAML 配置**：
  - 使用 2 个空格缩进
  - 保持一致的结构

- **提交信息**：
  - 使用清晰的提交信息
  - 第一行简短描述（50 字符以内）
  - 如需详细说明，空一行后添加
  - 使用中文或英文

#### 测试

在提交 PR 前，请确保：

1. 所有测试通过：
   ```bash
   python3 tests/test_engine.py
   ```

2. 对新功能添加测试
3. 确保代码覆盖率不降低

#### Pull Request 流程

1. 创建一个新分支：
   ```bash
   git checkout -b feature/your-feature-name
   ```

2. 进行您的更改并提交：
   ```bash
   git add .
   git commit -m "描述您的更改"
   ```

3. 推送到您的 fork：
   ```bash
   git push origin feature/your-feature-name
   ```

4. 在 GitHub 上创建 Pull Request

5. PR 描述应包含：
   - 更改的目的和背景
   - 实现方法的简要说明
   - 测试方法
   - 相关的 issue 编号（如果有）

#### Pull Request 检查清单

在提交 PR 前，请确认：

- [ ] 代码遵循项目的代码规范
- [ ] 已添加或更新相关测试
- [ ] 所有测试通过
- [ ] 已更新相关文档
- [ ] commit 信息清晰明了
- [ ] 代码没有引入安全漏洞
- [ ] 性能没有明显下降

## 安全问题

如果您发现安全漏洞，请**不要**在公开 issue 中报告。请直接联系维护者：

- 通过 GitHub 私信
- 或发送邮件至项目维护者

## 许可证

通过贡献代码，您同意您的贡献将在 MIT 许可证下发布。

## 行为准则

### 我们的承诺

我们承诺使参与我们的项目和社区的每个人都能获得无骚扰的体验。

### 我们的标准

积极行为的例子包括：

- 使用友好和包容的语言
- 尊重不同的观点和经验
- 优雅地接受建设性批评
- 关注对社区最有利的事情
- 对其他社区成员表示同情

不可接受的行为包括：

- 使用性化的语言或图像
- 挑衅、侮辱或贬低性评论
- 公开或私下骚扰
- 未经明确许可发布他人的私人信息
- 其他可以合理地被认为是不专业的行为

### 执行

不遵守行为准则的行为可以报告给项目维护者。所有投诉都将被审查和调查。

## 问题？

如果您有任何问题，欢迎在 GitHub Issues 中提问。

感谢您的贡献！🎉
