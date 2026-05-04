#!/usr/bin/env python3
"""
End-to-end tests for SEC-AUDITD Alert Engine
Tests all Python version implementations
"""

import unittest
import subprocess
import sys
import os
import tempfile
import json
import time
import signal
from pathlib import Path

# Get project root directory
PROJECT_ROOT = Path(__file__).parent.parent.absolute()
ALERT_ENGINE_DIR = PROJECT_ROOT / 'alert-engine'


class TestEngineE2E(unittest.TestCase):
    """端到端测试基类"""

    def setUp(self):
        """设置测试环境"""
        self.temp_dir = tempfile.mkdtemp()
        self.audit_log = os.path.join(self.temp_dir, 'audit.log')
        self.alert_log = os.path.join(self.temp_dir, 'alert.log')
        self.config_file = os.path.join(self.temp_dir, 'config.yaml')
        self.rules_dir = os.path.join(self.temp_dir, 'rules.d')
        os.makedirs(self.rules_dir)

        # 创建测试配置
        config_content = f"""
engine:
  input:
    type: file
    file: {self.audit_log}
  output:
    - type: file
      path: {self.alert_log}
      format: json
  rules:
    dir: {self.rules_dir}
    reload_interval: 60
"""
        with open(self.config_file, 'w') as f:
            f.write(config_content)

        # 创建测试规则
        self._create_test_rules()

        # 创建空的审计日志
        with open(self.audit_log, 'w') as f:
            pass

    def _create_test_rules(self):
        """创建测试规则"""
        rule_content = """
rules:
  - id: test_process_exec
    name: "测试进程执行规则"
    enabled: true
    severity: high
    match:
      key: "process_exec"
      filters:
        - "'/tmp' in exe"
    alert:
      message: "检测到可疑执行: {exe}"
      throttle: 0

  - id: test_network_connect
    name: "测试网络连接规则"
    enabled: true
    severity: medium
    match:
      key: "network_connect"
    alert:
      message: "检测到网络连接: {exe}"
      throttle: 0

  - id: test_aggregate
    name: "测试聚合规则"
    enabled: true
    severity: high
    match:
      key: "test_aggregate"
    aggregate:
      window: 10
      group_by: ["uid"]
      count: 3
    alert:
      message: "检测到频繁操作: {count} 次"
      throttle: 0
"""
        rule_file = os.path.join(self.rules_dir, 'test.yaml')
        with open(rule_file, 'w') as f:
            f.write(rule_content)

    def _append_audit_log(self, line):
        """追加审计日志"""
        with open(self.audit_log, 'a') as f:
            f.write(line + '\n')
            f.flush()

    def _wait_for_alerts(self, timeout=10):
        """等待告警生成"""
        start_time = time.time()
        while time.time() - start_time < timeout:
            if os.path.exists(self.alert_log):
                with open(self.alert_log, 'r') as f:
                    content = f.read()
                    if content.strip():
                        return content
            time.sleep(0.2)
        return ""

    def _read_alerts(self):
        """读取生成的告警"""
        if not os.path.exists(self.alert_log):
            return []

        alerts = []
        with open(self.alert_log, 'r') as f:
            for line in f:
                line = line.strip()
                if line:
                    try:
                        alerts.append(json.loads(line))
                    except json.JSONDecodeError:
                        pass
        return alerts

    def tearDown(self):
        """清理测试环境"""
        import shutil
        try:
            shutil.rmtree(self.temp_dir)
        except Exception:
            pass


class TestDefaultEngineE2E(TestEngineE2E):
    """测试默认 Python 3 引擎"""

    def test_basic_alert_generation(self):
        """测试基本告警生成"""
        engine_script = ALERT_ENGINE_DIR / 'engine.py'

        # 启动引擎进程
        proc = subprocess.Popen(
            ['python3', str(engine_script), self.config_file],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE
        )

        try:
            # 等待引擎启动
            time.sleep(2)

            # 写入测试事件
            test_event = (
                'type=EXECVE msg=audit(1234567890.123:456): argc=2 '
                'a0="/tmp/test" exe="/tmp/test" key="process_exec"'
            )
            self._append_audit_log(test_event)

            # 等待告警生成
            time.sleep(1)
            self._wait_for_alerts(timeout=5)

            # 读取告警
            alerts = self._read_alerts()

            # 验证告警
            self.assertGreater(len(alerts), 0, "应该生成至少一个告警")
            alert = alerts[0]
            self.assertEqual(alert['rule_id'], 'test_process_exec')
            self.assertEqual(alert['severity'], 'high')
            self.assertIn('/tmp/test', alert['message'])

        finally:
            # 停止引擎
            proc.terminate()
            try:
                proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                proc.kill()

    def test_aggregate_alerts(self):
        """测试聚合告警"""
        engine_script = ALERT_ENGINE_DIR / 'engine.py'

        proc = subprocess.Popen(
            ['python3', str(engine_script), self.config_file],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE
        )

        try:
            time.sleep(2)

            # 写入多个事件触发聚合
            for i in range(3):
                test_event = f'type=SYSCALL msg=audit(123456789{i}.123:45{i}): uid=1000 key="test_aggregate"'
                self._append_audit_log(test_event)
                time.sleep(0.3)

            # 等待告警生成
            time.sleep(1)
            self._wait_for_alerts(timeout=5)

            # 读取告警
            alerts = self._read_alerts()

            # 验证聚合告警
            aggregate_alerts = [a for a in alerts if a['rule_id'] == 'test_aggregate']
            self.assertGreater(len(aggregate_alerts), 0, "应该生成聚合告警")
            alert = aggregate_alerts[0]
            self.assertIn('3', alert['message'])

        finally:
            proc.terminate()
            try:
                proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                proc.kill()

    def test_reopens_audit_log_after_rotation(self):
        """测试 audit.log 轮转后继续读取新文件"""
        engine_script = ALERT_ENGINE_DIR / 'engine.py'

        proc = subprocess.Popen(
            ['python3', str(engine_script), self.config_file],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE
        )

        try:
            time.sleep(2)

            rotated_log = self.audit_log + '.1'
            os.rename(self.audit_log, rotated_log)
            with open(self.audit_log, 'w') as f:
                f.write(
                    'type=EXECVE msg=audit(1234567890.223:457): argc=2 '
                    'a0="/tmp/rotated" exe="/tmp/rotated" key="process_exec"\n'
                )

            self._wait_for_alerts(timeout=6)
            alerts = self._read_alerts()
            rotated_alerts = [
                a for a in alerts
                if a.get('rule_id') == 'test_process_exec'
                and '/tmp/rotated' in a.get('message', '')
            ]
            self.assertGreater(len(rotated_alerts), 0, "轮转后新 audit.log 的事件应生成告警")

        finally:
            proc.terminate()
            try:
                proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                proc.kill()


class TestLaunchScriptE2E(TestEngineE2E):
    """测试启动脚本"""

    def test_launch_with_default_version(self):
        """测试使用默认版本启动"""
        launch_script = ALERT_ENGINE_DIR / 'launch-engine.sh'

        proc = subprocess.Popen(
            ['bash', str(launch_script), self.config_file],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE
        )

        try:
            time.sleep(2)

            # 写入测试事件
            test_event = 'type=EXECVE msg=audit(1234567890.123:456): argc=2 exe="/tmp/suspicious" key="process_exec"'
            self._append_audit_log(test_event)

            # 等待告警
            time.sleep(1)
            self._wait_for_alerts(timeout=5)

            # 验证告警
            alerts = self._read_alerts()
            self.assertGreater(len(alerts), 0, "应该使用默认版本生成告警")

        finally:
            proc.terminate()
            try:
                proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                proc.kill()

    def test_launch_with_version_selection(self):
        """测试版本选择功能（验证脚本正确选择引擎文件）"""
        launch_script = ALERT_ENGINE_DIR / 'launch-engine.sh'

        # 测试脚本是否可以接受版本参数并正确显示信息
        result = subprocess.run(
            ['bash', str(launch_script), '--python-version', '3.6', '--help'],
            capture_output=True,
            text=True,
            timeout=5
        )

        # 应该显示帮助信息
        self.assertEqual(result.returncode, 0)
        self.assertIn('用法', result.stdout)

    def test_launch_version_scripts_exist(self):
        """测试版本特定的引擎脚本是否存在"""
        # 验证所有版本的引擎文件都存在
        for version_dir in ['py27', 'py35', 'py36']:
            engine_path = ALERT_ENGINE_DIR / version_dir / 'engine.py'
            self.assertTrue(
                engine_path.exists(),
                f"版本 {version_dir} 的引擎文件应该存在"
            )

    def test_launch_script_invalid_version(self):
        """测试无效的版本参数"""
        launch_script = ALERT_ENGINE_DIR / 'launch-engine.sh'

        result = subprocess.run(
            ['bash', str(launch_script), '--python-version', '99.99', self.config_file],
            capture_output=True,
            text=True,
            timeout=5
        )

        # 应该返回错误
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('不支持', result.stderr)

    def test_launch_script_help(self):
        """测试启动脚本帮助信息"""
        launch_script = ALERT_ENGINE_DIR / 'launch-engine.sh'

        result = subprocess.run(
            ['bash', str(launch_script), '--help'],
            capture_output=True,
            text=True,
            timeout=5
        )

        self.assertEqual(result.returncode, 0)
        self.assertIn('用法', result.stdout)
        self.assertIn('Python 版本', result.stdout)


class TestMultiVersionCompatibility(TestEngineE2E):
    """测试多版本兼容性"""

    def test_version_specific_engines_syntax(self):
        """测试版本特定引擎的语法兼容性"""
        test_event = 'type=EXECVE msg=audit(1234567890.123:456): argc=2 exe="/tmp/malware" key="process_exec"'

        # 测试可以直接执行的引擎（使用 python3）
        versions_to_test = [
            ('default', str(ALERT_ENGINE_DIR / 'engine.py')),
            ('py35', str(ALERT_ENGINE_DIR / 'py35' / 'engine.py')),
            ('py36', str(ALERT_ENGINE_DIR / 'py36' / 'engine.py')),
        ]

        for version_name, engine_path in versions_to_test:
            with self.subTest(version=version_name):
                # 清理之前的告警日志
                if os.path.exists(self.alert_log):
                    os.remove(self.alert_log)

                # 启动引擎
                proc = subprocess.Popen(
                    ['python3', engine_path, self.config_file],
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE
                )

                try:
                    time.sleep(2)

                    # 写入测试事件
                    self._append_audit_log(test_event)

                    # 等待告警
                    time.sleep(1)
                    self._wait_for_alerts(timeout=5)

                    # 验证告警
                    alerts = self._read_alerts()
                    self.assertGreater(
                        len(alerts), 0,
                        f"版本 {version_name} 应该生成告警"
                    )

                    alert = alerts[0]
                    self.assertEqual(alert['rule_id'], 'test_process_exec')
                    self.assertIn('/tmp/malware', alert['message'])

                finally:
                    proc.terminate()
                    try:
                        proc.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        proc.kill()


class TestSignalHandling(TestEngineE2E):
    """测试信号处理"""

    def test_sigterm_graceful_shutdown(self):
        """测试 SIGTERM 优雅退出"""
        engine_script = ALERT_ENGINE_DIR / 'engine.py'

        proc = subprocess.Popen(
            ['python3', str(engine_script), self.config_file],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE
        )

        try:
            time.sleep(2)

            # 发送 SIGTERM
            proc.terminate()

            # 等待进程退出
            returncode = proc.wait(timeout=5)

            # 验证优雅退出（返回码应该是负信号值或 0）
            self.assertIn(
                returncode, [0, -15, 143],
                "进程应该优雅退出"
            )

        except subprocess.TimeoutExpired:
            proc.kill()
            self.fail("进程未能在超时时间内退出")

    def test_sighup_reloads_rules(self):
        """测试 SIGHUP 触发规则重新加载"""
        engine_script = ALERT_ENGINE_DIR / 'engine.py'

        proc = subprocess.Popen(
            ['python3', str(engine_script), self.config_file],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE
        )

        try:
            time.sleep(2)

            # 发送 SIGHUP 触发规则重载
            proc.send_signal(signal.SIGHUP)

            # 等待短暂时间，确保引擎继续运行（没有崩溃）
            time.sleep(1)

            # 验证进程仍在运行
            self.assertIsNone(proc.poll(), "发送 SIGHUP 后引擎应继续运行")

            # 写入一个事件，验证引擎仍然工作
            test_event = 'type=EXECVE msg=audit(1234567890.999:999): exe="/tmp/after_reload" key="process_exec"'
            self._append_audit_log(test_event)
            self._wait_for_alerts(timeout=5)

            alerts = self._read_alerts()
            self.assertGreater(len(alerts), 0, "SIGHUP 后引擎应继续产生告警")

        finally:
            proc.terminate()
            try:
                proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                proc.kill()


class TestOutputFormats(TestEngineE2E):
    """测试不同的输出格式"""

    def setUp(self):
        """设置支持多种输出格式的测试环境"""
        super().setUp()
        self.text_alert_log = os.path.join(self.temp_dir, 'alert_text.log')

        # 创建包含 text 格式输出的配置
        config_content = f"""
engine:
  input:
    type: file
    file: {self.audit_log}
  output:
    - type: file
      path: {self.alert_log}
      format: json
    - type: file
      path: {self.text_alert_log}
      format: text
  rules:
    dir: {self.rules_dir}
    reload_interval: 60
"""
        with open(self.config_file, 'w') as f:
            f.write(config_content)

    def test_json_output_format(self):
        """测试 JSON 格式输出"""
        engine_script = ALERT_ENGINE_DIR / 'engine.py'

        proc = subprocess.Popen(
            ['python3', str(engine_script), self.config_file],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE
        )

        try:
            time.sleep(2)

            test_event = 'type=EXECVE msg=audit(1234567890.123:456): exe="/tmp/json_test" key="process_exec"'
            self._append_audit_log(test_event)
            self._wait_for_alerts(timeout=5)

            # 验证 JSON 格式
            alerts = self._read_alerts()
            self.assertGreater(len(alerts), 0, "应生成 JSON 格式告警")
            alert = alerts[0]
            self.assertIn('rule_id', alert)
            self.assertIn('severity', alert)
            self.assertIn('message', alert)
            self.assertIn('timestamp', alert)

        finally:
            proc.terminate()
            try:
                proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                proc.kill()

    def test_text_output_format(self):
        """测试文本格式输出"""
        engine_script = ALERT_ENGINE_DIR / 'engine.py'

        proc = subprocess.Popen(
            ['python3', str(engine_script), self.config_file],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE
        )

        try:
            time.sleep(2)

            test_event = 'type=EXECVE msg=audit(1234567890.123:456): exe="/tmp/text_test" key="process_exec"'
            self._append_audit_log(test_event)
            self._wait_for_alerts(timeout=5)

            # 等待文本格式文件写入
            start = time.time()
            while time.time() - start < 5:
                if os.path.exists(self.text_alert_log):
                    with open(self.text_alert_log, 'r') as f:
                        content = f.read()
                        if content.strip():
                            break
                time.sleep(0.2)

            self.assertTrue(os.path.exists(self.text_alert_log), "文本格式告警文件应存在")
            with open(self.text_alert_log, 'r') as f:
                text_content = f.read()
            self.assertTrue(text_content.strip(), "文本格式告警文件不应为空")

        finally:
            proc.terminate()
            try:
                proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                proc.kill()


class TestWhitelistE2E(TestEngineE2E):
    """测试白名单端到端过滤"""

    def setUp(self):
        """设置包含白名单规则的测试环境"""
        super().setUp()

        # 覆盖规则：带白名单的进程执行规则
        rule_content = """
rules:
  - id: whitelist_exec_rule
    name: "白名单进程执行规则"
    enabled: true
    severity: high
    match:
      key: "process_exec"
    whitelist:
      - exe: "/usr/bin/safe_process"
    alert:
      message: "可疑进程执行: {exe}"
      throttle: 0
"""
        rule_file = os.path.join(self.rules_dir, 'whitelist_test.yaml')
        with open(rule_file, 'w') as f:
            f.write(rule_content)

    def test_whitelist_blocks_alert(self):
        """测试白名单中的进程不产生告警"""
        engine_script = ALERT_ENGINE_DIR / 'engine.py'

        proc = subprocess.Popen(
            ['python3', str(engine_script), self.config_file],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE
        )

        try:
            time.sleep(2)

            # 写入白名单中的进程事件
            whitelisted_event = (
                'type=EXECVE msg=audit(1234567890.123:100): '
                'exe="/usr/bin/safe_process" key="process_exec"'
            )
            self._append_audit_log(whitelisted_event)
            time.sleep(2)

            # 白名单进程不应产生 whitelist_exec_rule 告警
            alerts = self._read_alerts()
            whitelist_rule_alerts = [a for a in alerts if a.get('rule_id') == 'whitelist_exec_rule']
            self.assertEqual(len(whitelist_rule_alerts), 0, "白名单进程不应触发告警")

        finally:
            proc.terminate()
            try:
                proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                proc.kill()

    def test_non_whitelist_triggers_alert(self):
        """测试非白名单进程正常产生告警"""
        engine_script = ALERT_ENGINE_DIR / 'engine.py'

        proc = subprocess.Popen(
            ['python3', str(engine_script), self.config_file],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE
        )

        try:
            time.sleep(2)

            # 写入非白名单进程事件
            suspicious_event = (
                'type=EXECVE msg=audit(1234567890.123:200): '
                'exe="/tmp/suspicious_proc" key="process_exec"'
            )
            self._append_audit_log(suspicious_event)
            self._wait_for_alerts(timeout=5)

            # 非白名单进程应产生告警
            alerts = self._read_alerts()
            whitelist_rule_alerts = [a for a in alerts if a.get('rule_id') == 'whitelist_exec_rule']
            self.assertGreater(len(whitelist_rule_alerts), 0, "非白名单进程应触发告警")

        finally:
            proc.terminate()
            try:
                proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                proc.kill()


class TestFilterExpressionsE2E(TestEngineE2E):
    """测试过滤器表达式的端到端行为"""

    def setUp(self):
        """设置包含过滤器规则的测试环境"""
        super().setUp()

        # 覆盖规则：带多个过滤条件的规则
        rule_content = """
rules:
  - id: filter_exec_rule
    name: "过滤器进程执行规则"
    enabled: true
    severity: critical
    match:
      key: "process_exec"
      filters:
        - "'/tmp' in exe"
    alert:
      message: "检测到 /tmp 执行: {exe}"
      throttle: 0

  - id: uid_filter_rule
    name: "UID 过滤规则"
    enabled: true
    severity: medium
    match:
      key: "process_exec"
      filters:
        - "uid == 0"
    alert:
      message: "Root 用户执行: {exe}"
      throttle: 0
"""
        rule_file = os.path.join(self.rules_dir, 'filter_test.yaml')
        with open(rule_file, 'w') as f:
            f.write(rule_content)

    def test_filter_matches_correctly(self):
        """测试过滤器正确过滤匹配事件"""
        engine_script = ALERT_ENGINE_DIR / 'engine.py'

        proc = subprocess.Popen(
            ['python3', str(engine_script), self.config_file],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE
        )

        try:
            time.sleep(2)

            # 匹配过滤器的事件（/tmp 路径）
            match_event = 'type=EXECVE msg=audit(1234567890.123:300): exe="/tmp/malware" uid=1000 key="process_exec"'
            self._append_audit_log(match_event)
            self._wait_for_alerts(timeout=5)

            alerts = self._read_alerts()
            filter_alerts = [a for a in alerts if a.get('rule_id') == 'filter_exec_rule']
            self.assertGreater(len(filter_alerts), 0, "匹配 /tmp 路径的事件应触发过滤器告警")

        finally:
            proc.terminate()
            try:
                proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                proc.kill()

    def test_filter_blocks_non_matching_event(self):
        """测试过滤器不匹配时不产生告警"""
        engine_script = ALERT_ENGINE_DIR / 'engine.py'

        proc = subprocess.Popen(
            ['python3', str(engine_script), self.config_file],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE
        )

        try:
            time.sleep(2)

            # 不匹配过滤器的事件（非 /tmp 路径）
            no_match_event = 'type=EXECVE msg=audit(1234567890.123:400): exe="/usr/bin/ls" uid=1000 key="process_exec"'
            self._append_audit_log(no_match_event)
            time.sleep(2)

            alerts = self._read_alerts()
            filter_alerts = [a for a in alerts if a.get('rule_id') == 'filter_exec_rule']
            self.assertEqual(len(filter_alerts), 0, "非 /tmp 路径的事件不应触发 filter_exec_rule 告警")

        finally:
            proc.terminate()
            try:
                proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                proc.kill()

    def test_uid_filter(self):
        """测试数值型 UID 过滤器"""
        engine_script = ALERT_ENGINE_DIR / 'engine.py'

        proc = subprocess.Popen(
            ['python3', str(engine_script), self.config_file],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE
        )

        try:
            time.sleep(2)

            # Root 用户执行（uid=0）
            root_event = 'type=EXECVE msg=audit(1234567890.123:500): exe="/usr/bin/passwd" uid=0 key="process_exec"'
            self._append_audit_log(root_event)
            self._wait_for_alerts(timeout=5)

            alerts = self._read_alerts()
            uid_alerts = [a for a in alerts if a.get('rule_id') == 'uid_filter_rule']
            self.assertGreater(len(uid_alerts), 0, "Root 用户执行应触发 uid_filter_rule 告警")

        finally:
            proc.terminate()
            try:
                proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                proc.kill()


class TestASTFallbackE2E(TestEngineE2E):
    """测试不使用 simpleeval 时 AST 回退求值的端到端行为"""

    def setUp(self):
        """设置测试环境，使用需要表达式求值的规则"""
        super().setUp()

        rule_content = """
rules:
  - id: ast_filter_rule
    name: "AST 回退过滤规则"
    enabled: true
    severity: high
    match:
      key: "file_write"
      filters:
        - "'/etc' in path"
    alert:
      message: "检测到 /etc 写入: {path}"
      throttle: 0
"""
        rule_file = os.path.join(self.rules_dir, 'ast_test.yaml')
        with open(rule_file, 'w') as f:
            f.write(rule_content)

    def test_engine_without_simpleeval(self):
        """测试在没有 simpleeval 时引擎仍能正确处理过滤器"""
        engine_script = ALERT_ENGINE_DIR / 'engine.py'

        # 通过设置 PYTHONPATH 排除 simpleeval，模拟其不可用的情况
        env = os.environ.copy()
        # 创建一个临时模块来屏蔽 simpleeval
        mock_simpleeval_dir = os.path.join(self.temp_dir, 'mock_modules')
        os.makedirs(mock_simpleeval_dir)
        with open(os.path.join(mock_simpleeval_dir, 'simpleeval.py'), 'w') as f:
            f.write("raise ImportError('simpleeval not available')\n")
        env['PYTHONPATH'] = mock_simpleeval_dir + os.pathsep + env.get('PYTHONPATH', '')

        proc = subprocess.Popen(
            ['python3', str(engine_script), self.config_file],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=env
        )

        try:
            time.sleep(2)

            # 写入匹配 /etc 路径的事件
            test_event = 'type=SYSCALL msg=audit(1234567890.123:600): path="/etc/passwd" key="file_write"'
            self._append_audit_log(test_event)
            self._wait_for_alerts(timeout=5)

            alerts = self._read_alerts()
            ast_alerts = [a for a in alerts if a.get('rule_id') == 'ast_filter_rule']
            self.assertGreater(len(ast_alerts), 0, "AST 回退求值应正确匹配 /etc 路径事件")

        finally:
            proc.terminate()
            try:
                proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                proc.kill()


def run_e2e_tests():
    """运行所有端到端测试"""
    loader = unittest.TestLoader()
    suite = unittest.TestSuite()

    # 添加所有测试用例
    suite.addTests(loader.loadTestsFromTestCase(TestDefaultEngineE2E))
    suite.addTests(loader.loadTestsFromTestCase(TestLaunchScriptE2E))
    suite.addTests(loader.loadTestsFromTestCase(TestMultiVersionCompatibility))
    suite.addTests(loader.loadTestsFromTestCase(TestSignalHandling))
    suite.addTests(loader.loadTestsFromTestCase(TestOutputFormats))
    suite.addTests(loader.loadTestsFromTestCase(TestWhitelistE2E))
    suite.addTests(loader.loadTestsFromTestCase(TestFilterExpressionsE2E))
    suite.addTests(loader.loadTestsFromTestCase(TestASTFallbackE2E))

    # 运行测试
    runner = unittest.TextTestRunner(verbosity=2)
    result = runner.run(suite)

    return result.wasSuccessful()


if __name__ == '__main__':
    success = run_e2e_tests()
    sys.exit(0 if success else 1)
