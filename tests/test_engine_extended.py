#!/usr/bin/env python3
"""
Comprehensive unit tests for SEC-AUDITD Alert Engine
目标: 提高测试覆盖率至 80% 以上
"""

import unittest
import sys
import os
import stat
import tempfile
import time
import types
from unittest.mock import patch

# Add parent directory to path
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', 'alert-engine'))

from engine import AuditParser, RuleEngine, AlertEngine  # noqa: E402


class TestAuditParserExtended(unittest.TestCase):
    """扩展的审计日志解析器测试"""

    def test_parse_line_with_type_only(self):
        """测试只有 type 的行"""
        line = 'type=SYSCALL'
        event = AuditParser.parse_line(line)
        self.assertIsNotNone(event)
        self.assertEqual(event['type'], 'SYSCALL')

    def test_parse_line_without_key(self):
        """测试没有 key 的行"""
        line = 'type=SYSCALL msg=audit(1234567890.123:456): pid=1000'
        event = AuditParser.parse_line(line)
        self.assertIsNotNone(event)
        self.assertNotIn('key', event)

    def test_parse_line_with_unquoted_key(self):
        """测试不带引号的 key"""
        line = 'type=SYSCALL msg=audit(1234567890.123:456): pid=1000 key=test_key'
        event = AuditParser.parse_line(line)
        self.assertIsNotNone(event)
        self.assertEqual(event['key'], 'test_key')

    def test_parse_line_exception_handling(self):
        """测试解析异常处理"""
        line = 'type='  # 不完整的行
        event = AuditParser.parse_line(line)
        # 不完整的行不应抛出异常，应返回 None 或空 dict
        self.assertIsInstance(event, (type(None), dict))

    def test_decode_audit_value_empty(self):
        """测试解码空值"""
        result = AuditParser.decode_audit_value("")
        self.assertEqual(result, "")

    def test_decode_audit_value_odd_length(self):
        """测试解码奇数长度的十六进制"""
        odd_hex = "2F746D7"  # 奇数长度
        result = AuditParser.decode_audit_value(odd_hex)
        self.assertEqual(result, odd_hex)  # 不应该解码

    def test_decode_audit_value_invalid_hex(self):
        """测试解码无效的十六进制"""
        invalid = "GHIJKL"
        result = AuditParser.decode_audit_value(invalid)
        self.assertEqual(result, invalid)

    def test_decode_audit_value_short(self):
        """测试解码短值 (< 4 字符)"""
        short = "AB"
        result = AuditParser.decode_audit_value(short)
        self.assertEqual(result, short)

    def test_decode_audit_value_non_printable(self):
        """测试解码非打印字符"""
        # 十六进制 00 01 02 03（非打印字符）
        non_printable_hex = "00010203"
        result = AuditParser.decode_audit_value(non_printable_hex)
        # 非打印字符不应被解码，应返回原始十六进制字符串
        self.assertEqual(result, non_printable_hex)

    def test_decode_audit_value_lowercase_plain_text(self):
        """测试类似十六进制的普通小写文本不被误解码"""
        plain = "cafe1234abcd"
        result = AuditParser.decode_audit_value(plain)
        self.assertEqual(result, plain)

    def test_decode_audit_value_numeric_hex_text(self):
        """测试不含 A-F 的合法 audit 十六进制文本可以解码"""
        result = AuditParser.decode_audit_value("62617368")
        self.assertEqual(result, "bash")

    def test_enrich_event_invalid_timestamp(self):
        """测试无效时间戳的事件丰富"""
        event = {'timestamp': 999999999999999}  # 无效的时间戳（超出 datetime 范围）
        enriched = AuditParser.enrich_event(event)
        # 无效时间戳不应导致崩溃，结果应为字典
        self.assertIsInstance(enriched, dict)
        # 无效时间戳不应添加 datetime 字段
        self.assertNotIn('datetime', enriched)

    def test_enrich_event_invalid_uid(self):
        """测试无效 UID 的事件丰富"""
        event = {'uid': 'invalid'}
        enriched = AuditParser.enrich_event(event)
        self.assertEqual(enriched['uid'], 'invalid')  # 保持原样

    def test_enrich_event_invalid_pid(self):
        """测试无效 PID 的事件丰富"""
        event = {'pid': 'invalid'}
        enriched = AuditParser.enrich_event(event)
        self.assertEqual(enriched['pid'], 'invalid')  # 保持原样

    def test_enrich_event_all_fields(self):
        """测试丰富所有字段"""
        event = {
            'timestamp': 1234567890.0,
            'uid': '1000',
            'gid': '1000',
            'auid': '1000',
            'euid': '1000',
            'egid': '1000',
            'pid': '12345',
            'comm': 'bash'
        }
        enriched = AuditParser.enrich_event(event)
        self.assertEqual(enriched['uid'], 1000)
        self.assertEqual(enriched['gid'], 1000)
        self.assertEqual(enriched['auid'], 1000)
        self.assertEqual(enriched['euid'], 1000)
        self.assertEqual(enriched['egid'], 1000)
        self.assertEqual(enriched['pid'], 12345)
        self.assertEqual(enriched['process'], 'bash')


class TestRuleEngineExtended(unittest.TestCase):
    """扩展的规则引擎测试"""

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

    def test_load_config_file_not_found(self):
        """测试配置文件不存在"""
        with self.assertRaises(SystemExit):
            RuleEngine('/nonexistent/config.yaml')

    def test_load_config_invalid_yaml(self):
        """测试无效的 YAML 配置"""
        invalid_config = os.path.join(self.temp_dir, 'invalid.yaml')
        with open(invalid_config, 'w') as f:
            f.write("invalid: yaml: content: {")

        with self.assertRaises(SystemExit):
            RuleEngine(invalid_config)

    def test_load_config_empty_file(self):
        """测试空配置文件"""
        empty_config = os.path.join(self.temp_dir, 'empty.yaml')
        with open(empty_config, 'w') as f:
            f.write("")

        with self.assertRaises(SystemExit):
            RuleEngine(empty_config)

    def test_load_rules_nonexistent_dir(self):
        """测试规则目录不存在"""
        config_content = """
engine:
  input:
    type: file
    file: /tmp/test.log
  output:
    - type: file
      path: /tmp/alert.log
  rules:
    dir: /nonexistent/rules.d/
    reload_interval: 60
"""
        config_file = os.path.join(self.temp_dir, 'config2.yaml')
        with open(config_file, 'w') as f:
            f.write(config_content)

        engine = RuleEngine(config_file)
        self.assertEqual(len(engine.rules), 0)

    def test_load_rules_invalid_yaml(self):
        """测试加载无效的规则 YAML"""
        invalid_rule = os.path.join(self.rules_dir, 'invalid.yaml')
        with open(invalid_rule, 'w') as f:
            f.write("invalid: yaml: {")

        # 创建有效配置
        config_content = f"""
engine:
  input:
    type: file
    file: /tmp/test.log
  output:
    - type: file
      path: /tmp/alert.log
  rules:
    dir: {self.rules_dir}
    reload_interval: 60
"""
        with open(self.config_file, 'w') as f:
            f.write(config_content)

        # Load the config file, should handle missing rules directory gracefully
        RuleEngine(self.config_file)
        # 应该跳过无效规则

    def test_load_rules_skips_duplicate_ids(self):
        """测试重复规则 ID 会被跳过，避免状态和限流冲突"""
        first_rule = os.path.join(self.rules_dir, '01-first.yaml')
        second_rule = os.path.join(self.rules_dir, '02-second.yaml')
        with open(first_rule, 'w') as f:
            f.write("""
rules:
  - id: duplicate_rule
    name: "第一条"
    match:
      key: "first"
    alert:
      message: "first"
""")
        with open(second_rule, 'w') as f:
            f.write("""
rules:
  - id: duplicate_rule
    name: "第二条"
    match:
      key: "second"
    alert:
      message: "second"
""")

        config_content = f"""
engine:
  input:
    type: file
    file: /tmp/test.log
  output:
    - type: file
      path: /tmp/alert.log
  rules:
    dir: {self.rules_dir}
    reload_interval: 60
"""
        with open(self.config_file, 'w') as f:
            f.write(config_content)

        engine = RuleEngine(self.config_file)
        duplicate_rules = [r for r in engine.rules if r.get('id') == 'duplicate_rule']

        self.assertEqual(len(duplicate_rules), 1)
        self.assertEqual(duplicate_rules[0]['name'], '第一条')

    def test_match_rule_with_list_keys(self):
        """测试匹配多个 key 的规则"""
        rule_content = """
rules:
  - id: test_multi_key
    name: "多Key测试"
    enabled: true
    severity: medium
    match:
      key: ["key1", "key2", "key3"]
    alert:
      message: "匹配多个key"
"""
        rule_file = os.path.join(self.rules_dir, 'multi_key.yaml')
        with open(rule_file, 'w') as f:
            f.write(rule_content)

        engine = RuleEngine(self.config_file)

        # 测试匹配
        event1 = {'key': 'key1'}
        event2 = {'key': 'key2'}
        event3 = {'key': 'other'}

        rule = engine.rules[0]
        self.assertTrue(engine._match_rule(event1, rule))
        self.assertTrue(engine._match_rule(event2, rule))
        self.assertFalse(engine._match_rule(event3, rule))

    def test_match_rule_with_filters(self):
        """测试带过滤器的规则匹配"""
        rule_content = """
rules:
  - id: test_filter
    name: "过滤器测试"
    enabled: true
    severity: high
    match:
      key: "test_key"
      filters:
        - "uid == 0"
        - "'/tmp' in exe"
    alert:
      message: "过滤器匹配"
"""
        rule_file = os.path.join(self.rules_dir, 'filter.yaml')
        with open(rule_file, 'w') as f:
            f.write(rule_content)

        engine = RuleEngine(self.config_file)
        rule = engine.rules[0]

        # 匹配的事件
        event_match = {'key': 'test_key', 'uid': 0, 'exe': '/tmp/test'}
        self.assertTrue(engine._match_rule(event_match, rule))

        # 不匹配的事件 (uid 不对)
        event_no_match1 = {'key': 'test_key', 'uid': 1000, 'exe': '/tmp/test'}
        self.assertFalse(engine._match_rule(event_no_match1, rule))

        # 不匹配的事件 (exe 不对)
        event_no_match2 = {'key': 'test_key', 'uid': 0, 'exe': '/usr/bin/test'}
        self.assertFalse(engine._match_rule(event_no_match2, rule))

    def test_match_rule_filter_exception(self):
        """测试过滤器异常处理"""
        rule = {
            'id': 'test',
            'match': {
                'key': 'test_key',
                'filters': ['undefined_var == 1']
            }
        }
        event = {'key': 'test_key'}
        engine = RuleEngine(self.config_file)

        # 应该处理异常并返回 False
        result = engine._match_rule(event, rule)
        self.assertFalse(result)

    def test_check_aggregate(self):
        """测试聚合功能"""
        rule_content = """
rules:
  - id: test_aggregate
    name: "聚合测试"
    enabled: true
    severity: medium
    match:
      key: "test_key"
    aggregate:
      window: 10
      group_by: ["uid"]
      count: 3
    alert:
      message: "聚合告警: {count} 次"
"""
        rule_file = os.path.join(self.rules_dir, 'aggregate.yaml')
        with open(rule_file, 'w') as f:
            f.write(rule_content)

        engine = RuleEngine(self.config_file)
        rule = engine.rules[0]

        event = {'key': 'test_key', 'uid': 1000}

        # 第一次不应该触发
        result1 = engine._check_aggregate(event, rule)
        self.assertIsNone(result1)

        # 第二次不应该触发
        result2 = engine._check_aggregate(event, rule)
        self.assertIsNone(result2)

        # 第三次应该触发
        result3 = engine._check_aggregate(event, rule)
        self.assertIsNotNone(result3)
        self.assertIn('count', result3)
        self.assertEqual(result3['count'], 3)

    def test_check_aggregate_with_unique(self):
        """测试带唯一值的聚合"""
        rule_content = """
rules:
  - id: test_unique
    name: "唯一值聚合测试"
    enabled: true
    severity: high
    match:
      key: "test_key"
    aggregate:
      window: 10
      group_by: ["uid"]
      unique: "exe"
      threshold: 3
    alert:
      message: "发现 {unique_count} 个不同程序"
"""
        rule_file = os.path.join(self.rules_dir, 'unique.yaml')
        with open(rule_file, 'w') as f:
            f.write(rule_content)

        engine = RuleEngine(self.config_file)
        rule = engine.rules[0]

        # 添加 3 个不同的 exe
        event1 = {'key': 'test_key', 'uid': 1000, 'exe': '/bin/ls'}
        event2 = {'key': 'test_key', 'uid': 1000, 'exe': '/bin/cat'}
        event3 = {'key': 'test_key', 'uid': 1000, 'exe': '/bin/grep'}

        result1 = engine._check_aggregate(event1, rule)
        self.assertIsNone(result1)

        result2 = engine._check_aggregate(event2, rule)
        self.assertIsNone(result2)

        result3 = engine._check_aggregate(event3, rule)
        self.assertIsNotNone(result3)
        self.assertIn('unique_count', result3)
        self.assertEqual(result3['unique_count'], 3)

    def test_in_whitelist_partial_match(self):
        """测试白名单部分匹配"""
        rule = {
            'whitelist': [
                {'process': 'apt'},
                {'exe': '/usr/bin'}
            ]
        }
        engine = RuleEngine(self.config_file)

        # 匹配
        event1 = {'process': 'apt-get', 'exe': '/usr/bin/apt-get'}
        self.assertTrue(engine._in_whitelist(event1, rule))

        # 匹配
        event2 = {'exe': '/usr/bin/ls'}
        self.assertTrue(engine._in_whitelist(event2, rule))

        # 不匹配
        event3 = {'process': 'suspicious', 'exe': '/tmp/bad'}
        self.assertFalse(engine._in_whitelist(event3, rule))

    def test_in_whitelist_exact_match(self):
        """测试白名单精确匹配"""
        rule = {
            'whitelist': [
                {'uid': 0}
            ]
        }
        engine = RuleEngine(self.config_file)

        # 匹配
        event1 = {'uid': 0}
        self.assertTrue(engine._in_whitelist(event1, rule))

        # 不匹配
        event2 = {'uid': 1000}
        self.assertFalse(engine._in_whitelist(event2, rule))

    def test_generate_alert_format_error(self):
        """测试告警消息格式化错误"""
        rule = {
            'id': 'test',
            'name': 'Test',
            'severity': 'high',
            'alert': {
                'message': '进程: {exe}, 用户: {nonexistent}'
            }
        }
        event = {'exe': '/bin/ls'}
        engine = RuleEngine(self.config_file)

        alert = engine._generate_alert(event, rule)
        # 应该处理格式化错误
        self.assertIn('message', alert)

    def test_generate_alert_with_non_string_values(self):
        """测试生成包含非字符串值的告警"""
        rule = {
            'id': 'test',
            'name': 'Test',
            'severity': 'medium',
            'alert': {
                'message': 'UID: {uid}, PID: {pid}'
            }
        }
        event = {'uid': 1000, 'pid': 12345, 'extra': {'nested': 'value'}}
        engine = RuleEngine(self.config_file)

        alert = engine._generate_alert(event, rule)
        self.assertIn('1000', alert['message'])
        self.assertIn('12345', alert['message'])

    def test_should_throttle_no_throttle(self):
        """测试无限流配置"""
        rule = {
            'id': 'test',
            'alert': {}  # 没有 throttle
        }
        event = {'key': 'test'}
        alert = {'event': event}
        engine = RuleEngine(self.config_file)

        # 应该不限流
        result = engine._should_throttle(alert, rule)
        self.assertFalse(result)

    def test_should_throttle_different_events(self):
        """测试不同事件的限流"""
        rule = {
            'id': 'test',
            'alert': {'throttle': 10}
        }
        engine = RuleEngine(self.config_file)

        # 两个不同的事件
        event1 = {'key': 'test', 'uid': 1000}
        event2 = {'key': 'test', 'uid': 2000}

        alert1 = {'event': event1}
        alert2 = {'event': event2}

        # 第一个不应该限流
        result1 = engine._should_throttle(alert1, rule)
        self.assertFalse(result1)

        # 第二个也不应该限流 (不同的 uid)
        result2 = engine._should_throttle(alert2, rule)
        self.assertFalse(result2)

    def test_process_event_disabled_rule(self):
        """测试禁用的规则"""
        rule_content = """
rules:
  - id: test_disabled
    name: "禁用规则"
    enabled: false
    severity: high
    match:
      key: "test_key"
    alert:
      message: "不应该触发"
"""
        rule_file = os.path.join(self.rules_dir, 'disabled.yaml')
        with open(rule_file, 'w') as f:
            f.write(rule_content)

        engine = RuleEngine(self.config_file)
        event = {'key': 'test_key'}

        alerts = engine.process_event(event)
        self.assertEqual(len(alerts), 0)

    def test_process_event_no_key(self):
        """测试没有 key 的事件"""
        engine = RuleEngine(self.config_file)
        event = {'type': 'SYSCALL'}

        alerts = engine.process_event(event)
        self.assertEqual(len(alerts), 0)

    def test_check_and_reload_rules(self):
        """测试规则重新加载"""
        rule_content = """
rules:
  - id: test_reload
    name: "重载测试"
    enabled: true
    severity: low
    match:
      key: "test_key"
    alert:
      message: "测试"
"""
        rule_file = os.path.join(self.rules_dir, 'reload.yaml')
        with open(rule_file, 'w') as f:
            f.write(rule_content)

        engine = RuleEngine(self.config_file)
        initial_count = len(engine.rules)

        # 修改 last_reload 使其触发重新加载
        engine.last_reload = time.time() - 100

        engine.check_and_reload_rules()

        # 规则应该重新加载
        self.assertEqual(len(engine.rules), initial_count)

    def test_reload_rules_cleans_removed_aggregate_state(self):
        """测试规则热重载后清理已删除聚合规则状态"""
        rule_content = """
rules:
  - id: aggregate_removed
    name: "聚合清理测试"
    enabled: true
    severity: high
    match:
      key: "aggregate_key"
    aggregate:
      window: 60
      group_by: ["uid"]
      count: 2
    alert:
      message: "测试"
      throttle: 0
"""
        rule_file = os.path.join(self.rules_dir, 'aggregate_cleanup.yaml')
        with open(rule_file, 'w') as f:
            f.write(rule_content)

        engine = RuleEngine(self.config_file)
        aggregate_rule = [r for r in engine.rules if r['id'] == 'aggregate_removed'][0]
        engine._check_aggregate({'key': 'aggregate_key', 'uid': 1000}, aggregate_rule)
        self.assertIn('aggregate_removed', engine.state)

        os.remove(rule_file)
        engine.reload_rules()

        self.assertNotIn('aggregate_removed', engine.state)

    def tearDown(self):
        """清理测试环境"""
        import shutil
        shutil.rmtree(self.temp_dir)


class TestAlertEngineExtended(unittest.TestCase):
    """扩展的告警引擎测试"""

    def setUp(self):
        """设置测试环境"""
        self.temp_dir = tempfile.mkdtemp()
        self.config_file = os.path.join(self.temp_dir, 'config.yaml')
        self.rules_dir = os.path.join(self.temp_dir, 'rules.d')
        self.alert_log = os.path.join(self.temp_dir, 'alert.log')
        os.makedirs(self.rules_dir)

        config_content = f"""
engine:
  input:
    type: file
    file: /tmp/test.log
  output:
    - type: file
      path: {self.alert_log}
      format: json
    - type: syslog
      enabled: false
  rules:
    dir: {self.rules_dir}
    reload_interval: 60
"""
        with open(self.config_file, 'w') as f:
            f.write(config_content)

    def test_init_alert_engine(self):
        """测试告警引擎初始化"""
        engine = AlertEngine(self.config_file)
        self.assertIsNotNone(engine.rule_engine)
        self.assertIsNotNone(engine.parser)
        self.assertEqual(engine.event_count, 0)
        self.assertEqual(engine.alert_count, 0)

    def test_process_line_valid(self):
        """测试处理有效行"""
        engine = AlertEngine(self.config_file)
        line = 'type=EXECVE msg=audit(1234567890.123:456): argc=2 a0="ls" key="test"'

        engine._process_line(line)
        self.assertEqual(engine.event_count, 1)

    def test_process_line_merges_path_record_by_serial(self):
        """测试同 serial 的 SYSCALL/PATH 行会合并后再匹配文件过滤规则"""
        rule_content = """
rules:
  - id: sshd_config_change
    name: "SSH 配置变更"
    enabled: true
    severity: high
    match:
      key: "sshd"
      filters:
        - "'sshd_config' in file"
    alert:
      message: "SSH 配置被修改: {file}"
      throttle: 0
"""
        with open(os.path.join(self.rules_dir, 'file.yaml'), 'w') as f:
            f.write(rule_content)

        engine = AlertEngine(self.config_file)
        syscall_line = (
            'type=SYSCALL msg=audit(1234567890.123:456): '
            'arch=c000003e syscall=2 success=yes comm="touch" '
            'key="sshd"'
        )
        path_line = (
            'type=PATH msg=audit(1234567890.123:456): '
            'item=0 name="/etc/ssh/sshd_config" inode=123'
        )

        eoe_line = 'type=EOE msg=audit(1234567890.123:456):'

        engine._process_line(syscall_line)
        self.assertEqual(engine.event_count, 0)
        engine._process_line(path_line)
        # PATH 记录应原地合并，等待 EOE 才触发处理（真实 auditd 行为）
        self.assertEqual(engine.event_count, 0)
        engine._process_line(eoe_line)

        self.assertEqual(engine.event_count, 1)
        self.assertEqual(engine.alert_count, 1)
        with open(self.alert_log, 'r') as f:
            self.assertIn('/etc/ssh/sshd_config', f.read())

    def test_process_line_flushes_pending_syscall_on_new_serial(self):
        """测试无 PATH 的 SYSCALL 在下一条 serial 到来时会刷出处理"""
        engine = AlertEngine(self.config_file)
        syscall_line = (
            'type=SYSCALL msg=audit(1234567890.123:456): '
            'arch=c000003e syscall=90 success=yes comm="chmod" '
            'key="perm_mod"'
        )
        next_line = 'type=EXECVE msg=audit(1234567890.124:457): argc=1 a0="ls" key="test"'

        engine._process_line(syscall_line)
        self.assertEqual(engine.event_count, 0)
        engine._process_line(next_line)

        self.assertEqual(engine.event_count, 2)

    def test_process_line_invalid(self):
        """测试处理无效行"""
        engine = AlertEngine(self.config_file)
        line = 'invalid log line'

        engine._process_line(line)
        # 应该处理异常

    def test_process_line_exception(self):
        """测试处理行时的异常"""
        engine = AlertEngine(self.config_file)

        # 模拟异常
        with patch.object(engine.parser, 'parse_line', side_effect=Exception("Test error")):
            engine._process_line('test line')
            # 应该捕获并记录异常

    def test_output_alert_to_file(self):
        """测试输出告警到文件"""
        engine = AlertEngine(self.config_file)
        alert = {
            'timestamp': '2024-01-01T00:00:00Z',
            'rule_id': 'test',
            'rule_name': 'Test Rule',
            'severity': 'high',
            'message': 'Test alert',
            'event': {'key': 'test'}
        }

        engine._output_alert(alert)

        # 检查文件是否创建
        self.assertTrue(os.path.exists(self.alert_log))
        self.assertEqual(stat.S_IMODE(os.stat(self.alert_log).st_mode), 0o600)

        # 检查内容
        with open(self.alert_log, 'r') as f:
            content = f.read()
            self.assertIn('test', content)

    def test_output_alert_does_not_create_directory_each_time(self):
        """测试输出目录在初始化时准备，写告警时不重复 makedirs"""
        engine = AlertEngine(self.config_file)
        alert = {
            'timestamp': '2024-01-01T00:00:00Z',
            'rule_id': 'test',
            'rule_name': 'Test Rule',
            'severity': 'high',
            'message': 'Test alert',
            'event': {'key': 'test'}
        }

        with patch('engine.os.makedirs') as makedirs_mock:
            engine._output_alert(alert)
            engine._output_alert(alert)

        makedirs_mock.assert_not_called()

    def test_output_alert_to_file_exception(self):
        """测试输出告警时的文件异常"""
        # 使用无效路径
        invalid_config = f"""
engine:
  input:
    type: file
    file: /tmp/test.log
  output:
    - type: file
      path: /invalid/path/alert.log
      format: json
  rules:
    dir: {self.rules_dir}
    reload_interval: 60
"""
        invalid_config_file = os.path.join(self.temp_dir, 'invalid.yaml')
        with open(invalid_config_file, 'w') as f:
            f.write(invalid_config)

        engine = AlertEngine(invalid_config_file)
        alert = {
            'timestamp': '2024-01-01T00:00:00Z',
            'rule_id': 'test',
            'severity': 'high',
            'message': 'Test',
            'event': {}
        }

        # 应该处理异常而不崩溃
        engine._output_alert(alert)

    def test_output_alert_syslog_disabled(self):
        """测试禁用的 syslog 输出"""
        engine = AlertEngine(self.config_file)
        alert = {
            'timestamp': '2024-01-01T00:00:00Z',
            'rule_id': 'test',
            'severity': 'high',
            'message': 'Test',
            'event': {}
        }

        # 不应该引发异常
        engine._output_alert(alert)

    def test_output_alert_syslog_openlog_once(self):
        """测试 syslog openlog 仅初始化一次"""
        syslog_config = f"""
engine:
  input:
    type: file
    file: /tmp/test.log
  output:
    - type: syslog
      enabled: true
  rules:
    dir: {self.rules_dir}
    reload_interval: 60
"""
        syslog_config_file = os.path.join(self.temp_dir, 'syslog.yaml')
        with open(syslog_config_file, 'w') as f:
            f.write(syslog_config)

        calls = {'openlog': 0, 'syslog': 0}

        def fake_openlog(name):
            calls['openlog'] += 1

        def fake_syslog(severity, message):
            calls['syslog'] += 1

        fake_module = types.SimpleNamespace(
            LOG_WARNING=4,
            openlog=fake_openlog,
            syslog=fake_syslog
        )
        alert = {
            'timestamp': '2024-01-01T00:00:00Z',
            'rule_id': 'test',
            'severity': 'high',
            'message': 'Test',
            'event': {}
        }

        with patch.dict(sys.modules, {'syslog': fake_module}):
            engine = AlertEngine(syslog_config_file)
            engine._output_alert(alert)
            engine._output_alert(alert)

        self.assertEqual(calls['openlog'], 1)
        self.assertEqual(calls['syslog'], 2)

    def test_run_file_mode_not_exists(self):
        """测试文件模式 - 文件不存在"""
        engine = AlertEngine(self.config_file)

        with self.assertRaises(SystemExit):
            engine._run_file_mode('/nonexistent/file.log')

    def test_run_invalid_input_type(self):
        """测试无效的输入类型"""
        invalid_config = f"""
engine:
  input:
    type: invalid_type
    file: /tmp/test.log
  output:
    - type: file
      path: {self.alert_log}
  rules:
    dir: {self.rules_dir}
    reload_interval: 60
"""
        invalid_config_file = os.path.join(self.temp_dir, 'invalid_type.yaml')
        with open(invalid_config_file, 'w') as f:
            f.write(invalid_config)

        engine = AlertEngine(invalid_config_file)

        with self.assertRaises(SystemExit):
            engine.run()

    def test_run_audisp_mode_not_implemented(self):
        """测试 audisp 模式未实现"""
        audisp_config = f"""
engine:
  input:
    type: audisp
    socket: /var/run/test.sock
  output:
    - type: file
      path: {self.alert_log}
  rules:
    dir: {self.rules_dir}
    reload_interval: 60
"""
        audisp_config_file = os.path.join(self.temp_dir, 'audisp.yaml')
        with open(audisp_config_file, 'w') as f:
            f.write(audisp_config)

        engine = AlertEngine(audisp_config_file)

        with self.assertRaises(SystemExit):
            engine.run()

    def tearDown(self):
        """清理测试环境"""
        import shutil
        shutil.rmtree(self.temp_dir)


class TestMainFunction(unittest.TestCase):
    """测试主函数"""

    def test_main_no_args(self):
        """测试没有参数"""
        from engine import main

        with patch('sys.argv', ['engine.py']):
            with self.assertRaises(SystemExit):
                main()

    def test_main_config_not_found(self):
        """测试配置文件不存在"""
        from engine import main

        with patch('sys.argv', ['engine.py', '/nonexistent/config.yaml']):
            with self.assertRaises(SystemExit):
                main()


def run_tests():
    """运行所有测试"""
    loader = unittest.TestLoader()
    suite = unittest.TestSuite()

    # 添加所有测试用例
    suite.addTests(loader.loadTestsFromTestCase(TestAuditParserExtended))
    suite.addTests(loader.loadTestsFromTestCase(TestRuleEngineExtended))
    suite.addTests(loader.loadTestsFromTestCase(TestAlertEngineExtended))
    suite.addTests(loader.loadTestsFromTestCase(TestMainFunction))

    # 运行测试
    runner = unittest.TextTestRunner(verbosity=2)
    result = runner.run(suite)

    return result.wasSuccessful()


if __name__ == '__main__':
    success = run_tests()
    sys.exit(0 if success else 1)
