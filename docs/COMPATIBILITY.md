# SEC-AUDITD 兼容性和部署指南

本文档详细说明 SEC-AUDITD 的兼容性支持和多种部署方式。

## 系统兼容性

### 支持的操作系统

| 操作系统 | 版本 | cgroups 支持 | 备注 |
|---------|------|-------------|------|
| Debian | 7+ (Wheezy+) | v1 (7-9), v2 (10+) | 完全支持 |
| Ubuntu | 16.04+ | v1 (16.04-18.04), v2 (20.04+) | 完全支持 |
| CentOS/RHEL | 7+ | v1 (7), v2 (8+) | 完全支持 |
| Fedora | 30+ | v2 | 完全支持 |
| openSUSE | 15+ | v2 | 完全支持 |

### cgroups 版本兼容性

#### cgroups v2（推荐）
- **内核版本**：Linux 4.5+
- **systemd 版本**：232+
- **支持功能**：
  - CPU 配额限制（CPUQuota）
  - 内存限制（MemoryMax, MemoryHigh）
  - I/O 权重控制（IOWeight）
  - 任务数限制（TasksMax）
- **适用系统**：Debian 10+, Ubuntu 20.04+, CentOS 8+, Fedora 30+

#### cgroups v1（兼容）
- **内核版本**：Linux 2.6.24+
- **systemd 版本**：任意
- **支持功能**：
  - CPU 配额限制（CPUQuota）
  - 内存限制（MemoryLimit）
  - 任务数限制（TasksMax）
- **适用系统**：Debian 7-9, Ubuntu 16.04-18.04, CentOS 7

#### 无 cgroups 支持（基本）
- **备选方案**：
  - 进程优先级（Nice）
  - 任务数限制（TasksMax）
  - OOM 分数调整（OOMScoreAdjust）
- **适用系统**：旧版 Linux 系统、容器环境

### Python 版本支持

- **Python 3.6+**：完全支持（推荐 3.8+）
- **Python 2.x**：不支持（已于 2020 年 EOL）
- **无 Python**：可使用二进制版本

## 部署方式

### 方式 1：快速安装（推荐）

最简单的部署方式，适用于大多数场景。

```bash
# 克隆仓库
git clone https://github.com/gwokfun/sec-auditd.git
cd sec-auditd

# 全自动安装
sudo ./scripts/quick-install.sh --auto
```

**特性：**
- ✅ 自动检测并安装依赖（auditd, python3, pip）
- ✅ 自动配置 cgroups 资源限制
- ✅ 自动启动服务
- ✅ 支持多种 Linux 发行版

**参数选项：**
```bash
# 最小化安装（不配置 cgroups）
sudo ./scripts/quick-install.sh --auto --minimal

# 使用二进制版本
sudo ./scripts/quick-install.sh --auto --with-binary

# 安装后不启动服务
sudo ./scripts/quick-install.sh --auto --no-start
```

### 方式 2：标准安装

使用原有的安装脚本，适合需要交互式确认的场景。

```bash
git clone https://github.com/gwokfun/sec-auditd.git
cd sec-auditd
sudo ./scripts/install.sh
```

### 方式 3：二进制部署

适用于没有 Python 环境或希望简化依赖的场景。

**步骤 1：构建二进制文件**

在有 Python 环境的开发机上：

```bash
cd sec-auditd
sudo ./scripts/build-binary.sh
```

生成的二进制文件位于 `dist/sec-auditd-engine`（约 30-50MB）。

**步骤 2：部署到目标系统**

```bash
# 复制二进制文件到目标系统
scp dist/sec-auditd-engine user@target:/tmp/

# 在目标系统上安装
cd sec-auditd
cp /tmp/sec-auditd-engine dist/
sudo ./scripts/quick-install.sh --with-binary --auto
```

**注意事项：**
- 二进制文件架构相关（x86_64/ARM64/etc.）
- 建议在与目标系统相似的环境中构建
- 仍需部署配置文件和规则文件

### 方式 4：在线安装（开发中）

未来支持直接从 GitHub 下载脚本安装：

```bash
curl -fsSL https://raw.githubusercontent.com/gwokfun/sec-auditd/main/scripts/quick-install.sh | sudo bash
```

## 资源限制配置

### 自动配置

快速安装脚本会自动配置资源限制。手动配置：

```bash
sudo /etc/sec-auditd/scripts/setup-cgroups.sh
```

脚本会自动：
1. 检测系统 cgroups 版本（v1/v2/none）
2. 计算合适的资源限制（CPU ~5%, 内存 ~5%）
3. 生成 systemd drop-in 配置
4. 重新加载 systemd

### 资源限制说明

默认配置：
- **CPU**：5% 的一个 CPU 核心
- **内存**：5% 系统内存（最小 64MB）
- **任务数**：最多 50 个任务
- **Nice 值**：10（较低优先级）
- **OOM 分数**：100（优先被终止）

### 验证资源限制

**cgroups v2：**
```bash
systemctl status sec-auditd-alert
cat /sys/fs/cgroup/system.slice/sec-auditd-alert.service/memory.current
cat /sys/fs/cgroup/system.slice/sec-auditd-alert.service/cpu.stat
```

**cgroups v1：**
```bash
systemctl status sec-auditd-alert
cat /sys/fs/cgroup/memory/system.slice/sec-auditd-alert.service/memory.usage_in_bytes
cat /sys/fs/cgroup/cpu,cpuacct/system.slice/sec-auditd-alert.service/cpuacct.usage
```

## 卸载

### 完全卸载

删除所有组件、配置和日志：

```bash
sudo ./scripts/uninstall.sh
```

### 保留日志

卸载但保留日志文件：

```bash
sudo ./scripts/uninstall.sh --keep-logs
```

卸载脚本会：
1. 停止并禁用 sec-auditd-alert 服务
2. 删除 systemd 服务文件
3. 移除 auditd 规则
4. 删除配置文件
5. 删除日志轮转配置
6. 可选删除日志文件

## 故障排查

### cgroups 检测失败

**问题**：系统无法检测 cgroups 版本

**解决方案**：
```bash
# 检查 cgroups 挂载
mount | grep cgroup

# cgroups v2
ls /sys/fs/cgroup/cgroup.controllers

# cgroups v1
ls /sys/fs/cgroup/cpu
```

### 二进制文件无法运行

**问题**：二进制文件在目标系统上报错

**可能原因**：
1. 架构不匹配（x86_64 vs ARM64）
2. glibc 版本不兼容
3. 缺少系统库

**解决方案**：
```bash
# 检查架构
uname -m

# 检查依赖
ldd dist/sec-auditd-engine

# 如果失败，使用 Python 脚本模式
sudo ./scripts/quick-install.sh --auto
```

### 依赖安装失败

**问题**：Python 依赖包安装失败

**解决方案**：
```bash
# 手动安装依赖
sudo python3 -m pip install --upgrade pip
sudo python3 -m pip install PyYAML simpleeval

# 或使用系统包管理器
sudo apt install python3-yaml  # Debian/Ubuntu
sudo yum install python3-pyyaml  # CentOS/RHEL
```

## 性能建议

### 不同场景的推荐配置

#### 高性能服务器（8+ 核心，16+ GB 内存）
- 使用 cgroups v2
- CPU 限制：5-10%
- 内存限制：5-10%
- 完整监控规则

#### 中等服务器（4-8 核心，4-16 GB 内存）
- 使用 cgroups v1/v2
- CPU 限制：5%
- 内存限制：5%
- 标准监控规则

#### 小型服务器（2-4 核心，2-4 GB 内存）
- 使用 cgroups v1 或基本控制
- CPU 限制：5%
- 内存限制：3-5%
- 最小化监控规则（--minimal）

#### 容器环境
- 可能无 cgroups 支持
- 使用基本进程控制
- 最小化监控规则
- 考虑使用二进制版本

## 升级指南

### 从旧版本升级

```bash
# 备份配置
sudo cp -r /etc/sec-auditd /etc/sec-auditd.backup

# 停止服务
sudo systemctl stop sec-auditd-alert

# 拉取最新代码
cd sec-auditd
git pull

# 重新安装
sudo ./scripts/quick-install.sh --auto

# 恢复自定义配置（如有）
sudo cp /etc/sec-auditd.backup/alert-engine/rules.d/custom.yaml \
     /etc/sec-auditd/alert-engine/rules.d/

# 重启服务
sudo systemctl restart sec-auditd-alert
```

## 常见问题

### Q: 是否支持 Python 2？
A: 不支持。Python 2 已于 2020 年停止维护。请使用 Python 3.6+ 或二进制版本。

### Q: 二进制版本与脚本版本有何区别？
A: 功能完全相同。二进制版本打包了 Python 解释器和所有依赖，文件较大但无需 Python 环境。

### Q: 在 Debian 7 上能否使用？
A: 可以。系统会自动检测并使用 cgroups v1 或基本进程控制。

### Q: 如何在不支持 cgroups 的系统上使用？
A: 脚本会自动降级到基本进程控制（Nice, TasksMax 等），仍可正常使用。

### Q: 资源限制能否自定义？
A: 可以。编辑 `/etc/systemd/system/sec-auditd-alert.service.d/resource-limits.conf` 后运行 `sudo systemctl daemon-reload && sudo systemctl restart sec-auditd-alert`。

### Q: 支持哪些包管理器？
A: apt (Debian/Ubuntu), yum (CentOS 7/RHEL 7), dnf (CentOS 8+/Fedora), zypper (openSUSE)。

## 参考资源

- [cgroups v1 文档](https://www.kernel.org/doc/Documentation/cgroup-v1/)
- [cgroups v2 文档](https://www.kernel.org/doc/Documentation/cgroup-v2.txt)
- [systemd 资源控制](https://www.freedesktop.org/software/systemd/man/systemd.resource-control.html)
- [PyInstaller 文档](https://pyinstaller.org/)
