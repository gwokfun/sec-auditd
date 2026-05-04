#!/usr/bin/env python3
"""
Unit tests for SEC-AUDITD Alert Engine
"""

import unittest
import sys
import os
import tempfile

# Add parent directory to path
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', 'alert-engine'))

from engine import AuditParser, RuleEngine  # noqa: E402, F401


class TestAuditParser(unittest.TestCase):
    """测试审计日志解析器"""

    def test_parse_simple_line(self):
        """测试解析简单的审计日志行"""
        line = 'type=EXECVE msg=audit(1234567890.123:456): argc=2 a0="ls" a1="/tmp" key="process_exec"'
        event = AuditParser.parse_line(line)

        self.assertIsNotNone(event)
        self.assertEqual(event['type'], 'EXECVE')
        self.assertEqual(event['key'], 'process_exec')
        self.assertAlmostEqual(event['timestamp'], 1234567890.123)
        self.assertEqual(event['serial'], '456')

    def test_parse_empty_line(self):
        """测试解析空行"""
        event = AuditParser.parse_line("")
        self.assertIsNone(event)

    def test_parse_invalid_line(self):
        """测试解析无效行"""
        event = AuditParser.parse_line("random text without structure")
        self.assertIsNone(event)

    def test_decode_audit_value_hex(self):
        """测试解码十六进制值"""
        hex_value = "2F746D70"  # /tmp in hex
        decoded = AuditParser.decode_audit_value(hex_value)
        self.assertEqual(decoded, "/tmp")

    def test_decode_audit_value_plain(self):
        """测试解码普通文本"""
        plain_value = "/usr/bin/ls"
        decoded = AuditParser.decode_audit_value(plain_value)
        self.assertEqual(decoded, plain_value)

    def test_enrich_event(self):
        """测试事件丰富"""
        event = {
            'timestamp': 1234567890.0,
            'uid': '1000',
            'pid': '12345',
            'comm': 'bash'
        }

        enriched = AuditParser.enrich_event(event)

        self.assertIn('datetime', enriched)
        self.assertEqual(enriched['datetime'], '2009-02-13T23:31:30Z')
        self.assertEqual(enriched['uid'], 1000)
        self.assertEqual(enriched['pid'], 12345)
        self.assertEqual(enriched['process'], 'bash')

    def test_enrich_event_sets_file_from_audit_name(self):
        """测试从 audit PATH name 字段补充 file 字段"""
        event = {'name': '/etc/ssh/sshd_config'}

        enriched = AuditParser.enrich_event(event)

        self.assertEqual(enriched['file'], '/etc/ssh/sshd_config')


class TestRuleEngine(unittest.TestCase):
    """测试规则引擎"""

    def setUp(self):
        """设置测试环境"""
        # 创建临时配置文件
        self.temp_dir = tempfile.mkdtemp()
        self.config_file = os.path.join(self.temp_dir, 'config.yaml')
        self.rules_dir = os.path.join(self.temp_dir, 'rules.d')
        os.makedirs(self.rules_dir)

        # 创建配置
        config_content = f"""
engine:
  input:
    type: file
    file: /tmp/test.log
  output:
    - type: file
      path: /tmp/alert.log
      format: json
  rules:
    dir: {self.rules_dir}
    reload_interval: 60
"""
        with open(self.config_file, 'w') as f:
            f.write(config_content)

        # 创建测试规则
        rule_content = """
rules:
  - id: test_rule
    name: "测试规则"
    enabled: true
    severity: high
    match:
      key: "process_exec"
    alert:
      message: "测试告警: {exe}"
      throttle: 300
"""
        rule_file = os.path.join(self.rules_dir, 'test.yaml')
        with open(rule_file, 'w') as f:
            f.write(rule_content)

    def test_load_config(self):
        """测试加载配置"""
        engine = RuleEngine(self.config_file)
        self.assertIsNotNone(engine.config)
        self.assertIn('engine', engine.config)

    def test_load_rules(self):
        """测试加载规则"""
        engine = RuleEngine(self.config_file)
        self.assertGreater(len(engine.rules), 0)
        self.assertEqual(engine.rules[0]['id'], 'test_rule')

    def test_match_rule(self):
        """测试规则匹配"""
        engine = RuleEngine(self.config_file)

        # 测试匹配的事件
        event = {'key': 'process_exec', 'exe': '/bin/ls'}
        rule = engine.rules[0]
        self.assertTrue(engine._match_rule(event, rule))

        # 测试不匹配的事件
        event_no_match = {'key': 'network_connect', 'exe': '/bin/curl'}
        self.assertFalse(engine._match_rule(event_no_match, rule))

    def test_whitelist(self):
        """测试白名单"""
        # 创建带白名单的规则
        rule_content = """
rules:
  - id: test_whitelist
    name: "白名单测试"
    enabled: true
    severity: high
    match:
      key: "process_exec"
    whitelist:
      - process: "apt-get"
      - process: "yum"
    alert:
      message: "测试告警"
      throttle: 0
"""
        rule_file = os.path.join(self.rules_dir, 'whitelist.yaml')
        with open(rule_file, 'w') as f:
            f.write(rule_content)

        engine = RuleEngine(self.config_file)

        # 查找白名单规则
        whitelist_rule = None
        for rule in engine.rules:
            if rule['id'] == 'test_whitelist':
                whitelist_rule = rule
                break

        self.assertIsNotNone(whitelist_rule)

        # 测试白名单中的进程
        event_whitelisted = {'key': 'process_exec', 'process': 'apt-get'}
        self.assertTrue(engine._in_whitelist(event_whitelisted, whitelist_rule))

        # 测试不在白名单中的进程
        event_not_whitelisted = {'key': 'process_exec', 'process': 'suspicious'}
        self.assertFalse(engine._in_whitelist(event_not_whitelisted, whitelist_rule))

    def test_generate_alert(self):
        """测试告警生成"""
        engine = RuleEngine(self.config_file)
        rule = engine.rules[0]
        event = {'key': 'process_exec', 'exe': '/bin/ls', 'uid': 1000}

        alert = engine._generate_alert(event, rule)

        self.assertIn('timestamp', alert)
        self.assertEqual(alert['rule_id'], 'test_rule')
        self.assertEqual(alert['severity'], 'high')
        self.assertIn('/bin/ls', alert['message'])

    def test_eval_filter_safe(self):
        """测试安全的过滤器求值"""
        engine = RuleEngine(self.config_file)

        # 测试简单的 in 操作
        event = {'exe': '/tmp/test', 'uid': 1000}
        result = engine._eval_filter("'/tmp' in exe", event)
        self.assertTrue(result)

        result = engine._eval_filter("'/usr' in exe", event)
        self.assertFalse(result)

    def tearDown(self):
        """清理测试环境"""
        import shutil
        shutil.rmtree(self.temp_dir)


class TestAlertThrottling(unittest.TestCase):
    """测试告警限流"""

    def setUp(self):
        """设置测试环境"""
        self.temp_dir = tempfile.mkdtemp()
        self.config_file = os.path.join(self.temp_dir, 'config.yaml')
        self.rules_dir = os.path.join(self.temp_dir, 'rules.d')
        os.makedirs(self.rules_dir)

        config_content = f"""
engine:
  input:
    type: file
    file: /tmp/test.log
  output:
    - type: file
      path: /tmp/alert.log
      format: json
  rules:
    dir: {self.rules_dir}
    reload_interval: 60
"""
        with open(self.config_file, 'w') as f:
            f.write(config_content)

        rule_content = """
rules:
  - id: throttle_test
    name: "限流测试"
    enabled: true
    severity: medium
    match:
      key: "test_key"
    alert:
      message: "限流测试告警"
      throttle: 10
"""
        rule_file = os.path.join(self.rules_dir, 'throttle.yaml')
        with open(rule_file, 'w') as f:
            f.write(rule_content)

    def test_throttling(self):
        """测试告警限流功能"""
        engine = RuleEngine(self.config_file)
        rule = engine.rules[0]
        event = {'key': 'test_key', 'uid': 1000}

        # 第一个告警应该通过
        alert1 = engine._generate_alert(event, rule)
        should_throttle1 = engine._should_throttle(alert1, rule)
        self.assertFalse(should_throttle1)

        # 第二个相同的告警应该被限流
        alert2 = engine._generate_alert(event, rule)
        should_throttle2 = engine._should_throttle(alert2, rule)
        self.assertTrue(should_throttle2)

    def tearDown(self):
        """清理测试环境"""
        import shutil
        shutil.rmtree(self.temp_dir)


def run_tests():
    """运行所有测试"""
    # 创建测试套件
    loader = unittest.TestLoader()
    suite = unittest.TestSuite()

    # 添加测试用例
    suite.addTests(loader.loadTestsFromTestCase(TestAuditParser))
    suite.addTests(loader.loadTestsFromTestCase(TestRuleEngine))
    suite.addTests(loader.loadTestsFromTestCase(TestAlertThrottling))

    # 运行测试
    runner = unittest.TextTestRunner(verbosity=2)
    result = runner.run(suite)

    return result.wasSuccessful()


if __name__ == '__main__':
    success = run_tests()
    sys.exit(0 if success else 1)
