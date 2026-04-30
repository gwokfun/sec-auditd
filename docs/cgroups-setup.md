# cgroups 资源限制配置指南

## 概述

本文档说明如何使用 Linux cgroups v2 限制 SEC-AUDITD alert-engine 的资源使用，确保在高负载情况下不会影响服务器上的其他服务。

## 目标

限制 alert-engine 的资源占用：
- **CPU**: < 5%
- **内存**: < 5% 系统总内存
- **I/O**: 低优先级

## 前提条件

1. Linux 系统支持 cgroups v2
2. systemd 版本 >= 220
3. Root 权限

### 检查 cgroups 版本

```bash
# 检查 cgroups v2 是否挂载
mount | grep cgroup

# 应该看到类似输出：
# cgroup2 on /sys/fs/cgroup type cgroup2 (rw,nosuid,nodev,noexec,relatime)

# 检查 cgroup.controllers 文件是否存在
ls -la /sys/fs/cgroup/cgroup.controllers
```

## 快速开始

### 1. 运行自动配置脚本

```bash
sudo /etc/sec-auditd/scripts/setup-cgroups.sh
```

脚本会自动：
- 检测系统资源（CPU 核心数、内存大小）
- 计算 5% 的资源限制
- 创建 systemd service drop-in 配置
- 重新加载 systemd 配置

### 2. 重启 alert-engine 服务

```bash
sudo systemctl restart sec-auditd-alert
```

### 3. 验证资源限制已生效

```bash
# 查看服务状态
sudo systemctl status sec-auditd-alert

# 查看 cgroup 设置
sudo systemctl show sec-auditd-alert | grep -E "(CPUQuota|MemoryMax|IOWeight)"

# 查看实际资源使用
sudo cat /sys/fs/cgroup/system.slice/sec-auditd-alert.service/memory.current
sudo cat /sys/fs/cgroup/system.slice/sec-auditd-alert.service/cpu.stat
```

## 手动配置

如果需要手动配置或自定义资源限制，请按照以下步骤操作。

### 1. 创建 systemd drop-in 目录

```bash
sudo mkdir -p /etc/systemd/system/sec-auditd-alert.service.d/
```

### 2. 创建资源限制配置文件

创建文件 `/etc/systemd/system/sec-auditd-alert.service.d/resource-limits.conf`:

```ini
[Service]
# CPU 限制: 5% 的一个 CPU 核心
CPUQuota=5%

# 内存限制 (示例: 512MB)
# 根据系统内存调整，建议设置为系统内存的 5%
MemoryMax=512M
MemoryHigh=460M

# I/O 权重 (10 = 最低优先级)
IOWeight=10

# 任务数限制 (防止 fork bomb)
TasksMax=50

# Nice 值 (10 = 较低优先级)
Nice=10

# OOM 分数调整 (优先被 OOM killer 杀死)
OOMScoreAdjust=100
```

### 3. 重新加载配置并重启服务

```bash
sudo systemctl daemon-reload
sudo systemctl restart sec-auditd-alert
```

## 资源限制说明

### CPU 限制 (CPUQuota)

- `CPUQuota=5%` 表示限制使用 5% 的一个 CPU 核心
- 在多核系统上，5% 表示单核的 5%
- 示例：
  - 单核系统：5% = 0.05 个核心
  - 双核系统：5% = 0.05 个核心（最多）
  - 四核系统：5% = 0.05 个核心（最多）

### 内存限制 (MemoryMax/MemoryHigh)

- `MemoryMax`: 硬限制，超过此值进程会被 OOM killer 杀死
- `MemoryHigh`: 软限制，超过此值会触发内存回收压力
- 建议 `MemoryHigh` 设置为 `MemoryMax` 的 90%

计算公式：
```
内存限制 (MB) = 系统总内存 (MB) × 5% ÷ 100
```

### I/O 权重 (IOWeight)

- 范围: 1-10000
- 10 = 最低优先级
- 100 = 默认优先级
- 1000 = 最高优先级

### 任务数限制 (TasksMax)

- 限制服务可以创建的最大进程/线程数
- 防止 fork bomb 攻击
- alert-engine 是单线程应用，50 个任务足够

### Nice 值

- 范围: -20 (最高优先级) 到 19 (最低优先级)
- 10 = 较低优先级，确保其他服务优先获得 CPU

### OOM 分数 (OOMScoreAdjust)

- 范围: -1000 到 1000
- 值越高，内存不足时越容易被杀死
- 100 = 较高的 OOM 分数，保护其他重要服务

## 监控资源使用

### 使用 systemctl 查看

```bash
# 查看服务状态和资源使用
sudo systemctl status sec-auditd-alert

# 查看详细的 cgroup 设置
sudo systemctl show sec-auditd-alert
```

### 使用 cgroup 接口查看

```bash
# 查看 CPU 使用统计
sudo cat /sys/fs/cgroup/system.slice/sec-auditd-alert.service/cpu.stat

# 查看内存使用
sudo cat /sys/fs/cgroup/system.slice/sec-auditd-alert.service/memory.current
sudo cat /sys/fs/cgroup/system.slice/sec-auditd-alert.service/memory.max
sudo cat /sys/fs/cgroup/system.slice/sec-auditd-alert.service/memory.stat

# 查看 I/O 统计
sudo cat /sys/fs/cgroup/system.slice/sec-auditd-alert.service/io.stat
```

### 使用性能测试脚本

```bash
# 运行性能测试（默认 30 秒，10000 条日志）
sudo /etc/sec-auditd/scripts/test-performance.sh

# 自定义测试参数（60 秒，20000 条日志）
sudo /etc/sec-auditd/scripts/test-performance.sh 60 20000
```

性能测试会：
1. 生成大量测试日志
2. 启动 alert-engine 处理日志
3. 监控资源使用情况（CPU、内存、线程、文件描述符）
4. 分析并评估是否满足 5% 的目标

### 使用 top/htop 监控

```bash
# 使用 top
top -p $(pgrep -f "alert-engine/engine.py")

# 或使用 htop（需要安装）
htop -p $(pgrep -f "alert-engine/engine.py")
```

### 使用 pidstat 监控

```bash
# 安装 sysstat（如果未安装）
sudo apt-get install sysstat  # Debian/Ubuntu
sudo yum install sysstat       # RHEL/CentOS

# 每 2 秒报告一次进程统计
pidstat -p $(pgrep -f "alert-engine/engine.py") 2
```

## 性能调优

### 场景 1: CPU 使用过高

如果 CPU 使用超过 5%，可以：

1. **降低 CPU 配额**
   ```ini
   CPUQuota=3%
   ```

2. **增加日志处理延迟**

   编辑 `alert-engine/engine.py` 中的 sleep 时间：
   ```python
   time.sleep(1.0)  # 增加到 1 秒
   ```

3. **减少规则复杂度**

   - 简化正则表达式
   - 减少过滤器数量
   - 禁用不必要的规则

### 场景 2: 内存使用过高

如果内存使用超过 5%，可以：

1. **降低内存限制**
   ```ini
   MemoryMax=256M
   MemoryHigh=230M
   ```

2. **减少聚合窗口大小**

   编辑规则文件中的 `window` 参数：
   ```yaml
   aggregate:
     window: 30  # 从 60 减少到 30 秒
   ```

3. **增加告警限流**

   增加 `throttle` 值以减少内存中的缓存：
   ```yaml
   alert:
     throttle: 600  # 增加到 10 分钟
   ```

### 场景 3: 监控高负载场景

在高日志量场景下测试：

```bash
# 生成大量测试日志
sudo /etc/sec-auditd/scripts/test-performance.sh 300 100000

# 持续监控 5 分钟
sudo watch -n 2 'systemctl status sec-auditd-alert | grep -E "(Memory|CPU)"'
```

## 故障排查

### 问题 1: 服务无法启动

```bash
# 查看服务日志
sudo journalctl -u sec-auditd-alert -n 50

# 检查配置语法
sudo systemd-analyze verify sec-auditd-alert.service
```

### 问题 2: 内存限制导致 OOM

如果服务被 OOM killer 杀死：

```bash
# 查看 OOM 日志
sudo dmesg | grep -i "out of memory"
sudo journalctl -k | grep -i "oom"

# 增加内存限制
sudo vim /etc/systemd/system/sec-auditd-alert.service.d/resource-limits.conf
# 修改 MemoryMax 值

sudo systemctl daemon-reload
sudo systemctl restart sec-auditd-alert
```

### 问题 3: CPU 限制导致处理延迟

如果日志处理延迟过高：

```bash
# 检查日志积压
sudo ls -lh /var/log/audit/audit.log

# 临时增加 CPU 配额（需要权衡资源使用）
sudo systemctl set-property sec-auditd-alert.service CPUQuota=10%

# 永久修改配置
sudo vim /etc/systemd/system/sec-auditd-alert.service.d/resource-limits.conf
```

## 最佳实践

1. **监控告警延迟**

   定期检查告警是否及时生成：
   ```bash
   # 比较审计日志和告警日志的时间戳
   sudo tail /var/log/audit/audit.log
   sudo tail /var/log/sec-auditd/alert.log
   ```

2. **定期审查资源使用**

   每周运行性能测试，确保资源使用在预期范围内。

3. **根据环境调整**

   - 开发环境：可以放宽限制
   - 生产环境：严格限制以保护关键服务
   - 高负载环境：可能需要专用服务器

4. **备份配置**

   ```bash
   sudo cp -r /etc/systemd/system/sec-auditd-alert.service.d/ \
              /etc/sec-auditd/backup/
   ```

5. **文档化自定义配置**

   记录任何偏离默认 5% 限制的更改及其原因。

## 参考资料

- [systemd Resource Control](https://www.freedesktop.org/software/systemd/man/systemd.resource-control.html)
- [cgroups v2 Documentation](https://www.kernel.org/doc/html/latest/admin-guide/cgroup-v2.html)
- [Linux Memory Management](https://www.kernel.org/doc/html/latest/admin-guide/mm/index.html)

## 总结

通过合理配置 cgroups 资源限制，可以确保 SEC-AUDITD alert-engine 在高负载情况下不会影响服务器上的其他服务。建议：

- 使用自动配置脚本快速部署
- 定期运行性能测试验证
- 根据实际环境调整限制
- 监控资源使用趋势
- 及时响应告警和异常
