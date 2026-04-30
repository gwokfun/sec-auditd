#!/usr/bin/env python3
"""
SEC-AUDITD Alert Engine
轻量级告警引擎 - 读取 auditd 事件，应用规则，生成告警
"""

import os
import sys
import json
import yaml
import time
import re
import logging
import signal
from datetime import datetime
from collections import defaultdict, deque
from typing import Dict, List, Any, Optional

try:
    from simpleeval import simple_eval, EvalWithCompoundTypes
    HAS_SIMPLEEVAL = True
except ImportError:
    HAS_SIMPLEEVAL = False
    import ast

# 日志配置
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s [%(levelname)s] %(message)s',
    handlers=[
        logging.StreamHandler(sys.stdout)
    ]
)
logger = logging.getLogger('alert-engine')


class AuditParser:
    """Auditd 日志解析器"""

    @staticmethod
    def parse_line(line: str) -> Optional[Dict[str, Any]]:
        """解析单行 audit 日志"""
        if not line or not line.strip():
            return None

        event = {}

        try:
            # 解析基本格式: type=TYPE msg=audit(timestamp:serial): key=value ...
            if 'type=' in line:
                # 提取 type
                type_match = re.search(r'type=(\S+)', line)
                if type_match:
                    event['type'] = type_match.group(1)

                # 提取 msg 中的时间戳
                msg_match = re.search(r'msg=audit\(([0-9.]+):([0-9]+)\)', line)
                if msg_match:
                    event['timestamp'] = float(msg_match.group(1))
                    event['serial'] = msg_match.group(2)

                # 解析 key=value 对
                # 处理带引号和不带引号的值
                for match in re.finditer(r'(\w+)=("(?:[^"\\]|\\.)*"|[^\s]+)', line):
                    key = match.group(1)
                    value = match.group(2)
                    # 去除引号
                    if value.startswith('"') and value.endswith('"'):
                        value = value[1:-1]
                    # 转换十六进制编码的值
                    if key in ['comm', 'exe', 'cwd'] and value:
                        value = AuditParser.decode_audit_value(value)
                    event[key] = value

                # 提取 key（审计规则的标识）
                key_match = re.search(r'key="([^"]+)"', line)
                if key_match:
                    event['key'] = key_match.group(1)
                elif ' key=' in line:
                    key_match = re.search(r' key=(\S+)', line)
                    if key_match:
                        event['key'] = key_match.group(1)

                return event
        except (ValueError, AttributeError, KeyError) as e:
            logger.debug(f"Failed to parse line: {e}")

        return None

    @staticmethod
    def decode_audit_value(value: str) -> str:
        """解码 audit 十六进制编码的值"""
        try:
            if not value:
                return value
            # 检查是否为十六进制编码（如 2F62696E2F6C73）
            if all(c in '0123456789ABCDEFabcdef' for c in value.replace(' ', '')):
                if len(value) % 2 == 0 and len(value) > 4:
                    try:
                        decoded = bytes.fromhex(value).decode('utf-8', errors='replace')
                        if decoded.isprintable() or '\n' in decoded or '\t' in decoded:
                            return decoded
                    except (ValueError, UnicodeDecodeError) as e:
                        logger.debug(f"Failed to decode hex value: {e}")
            return value
        except (ValueError, UnicodeDecodeError) as e:
            logger.debug(f"Unexpected error decoding value: {e}")
            return value

    @staticmethod
    def enrich_event(event: Dict[str, Any]) -> Dict[str, Any]:
        """丰富事件信息"""
        # 添加可读时间
        if 'timestamp' in event:
            try:
                dt = datetime.fromtimestamp(event['timestamp'])
                event['datetime'] = dt.isoformat()
            except (ValueError, OSError, OverflowError):
                pass

        # 提取进程信息
        if 'comm' in event:
            event['process'] = event['comm']

        # UID/GID 转换
        for field in ['uid', 'gid', 'auid', 'euid', 'egid']:
            if field in event:
                try:
                    event[field] = int(event[field])
                except (ValueError, TypeError):
                    pass

        # PID 转换
        if 'pid' in event:
            try:
                event['pid'] = int(event['pid'])
            except (ValueError, TypeError):
                pass

        return event


class RuleEngine:
    """规则引擎"""

    def __init__(self, config_path: str):
        self.config = self._load_config(config_path)
        self.rules = self._load_rules()
        self.state = defaultdict(lambda: defaultdict(deque))
        self.alert_cache = {}
        self.last_reload = time.time()
        self.reload_interval = self.config['engine']['rules'].get('reload_interval', 60)

    def _load_config(self, path: str) -> Dict:
        """加载配置"""
        try:
            with open(path, 'r', encoding='utf-8') as f:
                config = yaml.safe_load(f)
                if not config:
                    raise ValueError("Empty configuration file")
                return config
        except FileNotFoundError:
            logger.error(f"Config file not found: {path}")
            sys.exit(1)
        except yaml.YAMLError as e:
            logger.error(f"Failed to parse config YAML: {e}")
            sys.exit(1)
        except Exception as e:
            logger.error(f"Failed to load config from {path}: {e}")
            sys.exit(1)

    def _load_rules(self) -> List[Dict]:
        """加载规则"""
        rules = []
        rules_dir = self.config['engine']['rules']['dir']

        if not os.path.exists(rules_dir):
            logger.warning(f"Rules directory not found: {rules_dir}")
            return rules

        for filename in sorted(os.listdir(rules_dir)):
            if filename.endswith('.yaml') or filename.endswith('.yml'):
                filepath = os.path.join(rules_dir, filename)
                try:
                    with open(filepath, 'r', encoding='utf-8') as f:
                        rule_file = yaml.safe_load(f)
                        if rule_file and 'rules' in rule_file:
                            rules.extend(rule_file['rules'])
                            logger.info(f"Loaded rules from {filename}")
                except yaml.YAMLError as e:
                    logger.error(f"Failed to parse YAML in {filename}: {e}")
                except FileNotFoundError:
                    logger.error(f"Rule file not found: {filename}")
                except Exception as e:
                    logger.error(f"Failed to load rules from {filename}: {e}")

        logger.info(f"Total {len(rules)} rules loaded")
        return rules

    def check_and_reload_rules(self):
        """检查并重新加载规则"""
        now = time.time()
        if now - self.last_reload > self.reload_interval:
            logger.info("Reloading rules...")
            self.rules = self._load_rules()
            self.last_reload = now

    def process_event(self, event: Dict[str, Any]) -> List[Dict]:
        """处理事件，返回告警列表"""
        alerts = []

        if not event or 'key' not in event:
            return alerts

        for rule in self.rules:
            if not rule.get('enabled', True):
                continue

            # 检查是否匹配
            if self._match_rule(event, rule):
                # 检查是否在白名单
                if self._in_whitelist(event, rule):
                    continue

                # 检查聚合条件
                if 'aggregate' in rule:
                    if not self._check_aggregate(event, rule):
                        continue

                # 生成告警
                alert = self._generate_alert(event, rule)

                # 检查告警限流
                if not self._should_throttle(alert, rule):
                    alerts.append(alert)

        return alerts

    def _match_rule(self, event: Dict, rule: Dict) -> bool:
        """检查事件是否匹配规则"""
        match = rule.get('match', {})

        # 检查 key
        key = match.get('key')
        if key:
            if isinstance(key, list):
                if event.get('key') not in key:
                    return False
            else:
                if event.get('key') != key:
                    return False

        # 检查过滤器
        filters = match.get('filters', [])
        for filter_expr in filters:
            try:
                if not self._eval_filter(filter_expr, event):
                    return False
            except Exception as e:
                logger.debug(f"Filter evaluation failed: {e}")
                return False

        return True

    def _eval_filter(self, expr: str, event: Dict) -> bool:
        """评估过滤表达式（安全实现）"""
        try:
            # 创建安全的上下文
            context = {}
            for key, value in event.items():
                if isinstance(value, (str, int, float, bool)):
                    context[key] = value

            # 使用安全的表达式求值
            if HAS_SIMPLEEVAL:
                # 使用 simpleeval 库进行安全求值
                return bool(simple_eval(expr, names=context))
            else:
                # 回退到基于 AST 的安全实现
                # 注意：这个实现只支持简单的表达式
                logger.warning("simpleeval not available, using limited expression evaluation. Install with: pip install simpleeval")
                return self._safe_eval_fallback(expr, context)
        except (NameError, SyntaxError, ValueError) as e:
            logger.debug(f"Filter eval error: {e}")
            return False

    def _safe_eval_fallback(self, expr: str, context: Dict) -> bool:
        """安全的回退表达式求值（仅支持简单的 in 操作）"""
        # 这是一个简化的实现，仅支持常见的模式
        # 例如: "'text' in field"
        try:
            # 检查是否为简单的 in 表达式
            if ' in ' in expr:
                parts = expr.split(' in ')
                if len(parts) == 2:
                    needle = parts[0].strip().strip("'\"")
                    haystack_key = parts[1].strip()
                    if haystack_key in context:
                        haystack = str(context[haystack_key])
                        return needle in haystack
            # 对于其他表达式，使用受限的 eval
            # 移除危险的内置函数访问
            safe_dict = {"__builtins__": {}}
            safe_dict.update(context)
            return bool(eval(expr, safe_dict, {}))
        except Exception as e:
            logger.debug(f"Fallback eval error: {e}")
            return False

    def _check_aggregate(self, event: Dict, rule: Dict) -> bool:
        """检查聚合条件"""
        agg = rule['aggregate']
        window = agg.get('window', 60)
        group_by = agg.get('group_by', [])

        # 构建分组key
        group_key = tuple(str(event.get(k, '')) for k in group_by)
        rule_id = rule['id']

        # 添加到窗口
        now = time.time()
        self.state[rule_id][group_key].append((now, event))

        # 清理过期事件
        cutoff = now - window
        while (self.state[rule_id][group_key] and
               self.state[rule_id][group_key][0][0] < cutoff):
            self.state[rule_id][group_key].popleft()

        # 检查阈值
        count = len(self.state[rule_id][group_key])
        threshold = agg.get('count') or agg.get('threshold', 0)

        if 'unique' in agg:
            # 统计唯一值
            field = agg['unique']
            unique_values = set(str(e.get(field, '')) for _, e in self.state[rule_id][group_key])
            count = len(unique_values)
            # 将唯一值计数添加到事件中，用于告警消息
            event['unique_count'] = count

        # 将计数添加到事件中，用于告警消息
        event['count'] = count

        return count >= threshold

    def _in_whitelist(self, event: Dict, rule: Dict) -> bool:
        """检查是否在白名单"""
        whitelist = rule.get('whitelist', [])

        for entry in whitelist:
            match = True
            for key, value in entry.items():
                event_value = event.get(key, '')
                if isinstance(event_value, str):
                    # 支持部分匹配
                    if value not in event_value:
                        match = False
                        break
                elif event_value != value:
                    match = False
                    break
            if match:
                return True

        return False

    def _generate_alert(self, event: Dict, rule: Dict) -> Dict:
        """生成告警"""
        alert_config = rule.get('alert', {})
        message = alert_config.get('message', 'Alert triggered')

        # 格式化消息
        try:
            # 格式化消息
            format_ctx = {}
            for key, value in event.items():
                if isinstance(value, (str, int, float, bool)):
                    format_ctx[key] = value
                else:
                    format_ctx[key] = str(value)

            message = message.format(**format_ctx)
        except (KeyError, ValueError) as e:
            logger.debug(f"Message format error: {e}")

        return {
            'timestamp': datetime.now(datetime.UTC).isoformat().replace('+00:00', 'Z') if hasattr(datetime, 'UTC') else datetime.utcnow().isoformat() + 'Z',
            'rule_id': rule['id'],
            'rule_name': rule['name'],
            'severity': rule.get('severity', 'medium'),
            'message': message,
            'event': event
        }

    def _should_throttle(self, alert: Dict, rule: Dict) -> bool:
        """检查告警是否应该被限流"""
        throttle = rule.get('alert', {}).get('throttle', 0)
        if throttle == 0:
            return False

        # 生成缓存key（基于规则ID和核心字段）
        event = alert['event']
        cache_key_parts = [rule['id']]

        # 添加关键字段到缓存key
        for field in ['uid', 'process', 'exe', 'file', 'key']:
            if field in event:
                cache_key_parts.append(str(event[field]))

        cache_key = ':'.join(cache_key_parts)

        now = time.time()
        if cache_key in self.alert_cache:
            last_time = self.alert_cache[cache_key]
            if now - last_time < throttle:
                return True

        self.alert_cache[cache_key] = now
        return False


class AlertEngine:
    """告警引擎主类"""

    def __init__(self, config_path: str):
        self.rule_engine = RuleEngine(config_path)
        self.config = self.rule_engine.config
        self.parser = AuditParser()
        self.event_count = 0
        self.alert_count = 0

    def run(self):
        """运行引擎"""
        input_config = self.config['engine']['input']
        input_type = input_config['type']

        logger.info(f"Starting alert engine in {input_type} mode")

        if input_type == 'file':
            self._run_file_mode(input_config['file'])
        elif input_type == 'audisp':
            logger.error("Audisp mode not yet implemented")
            sys.exit(1)
        else:
            logger.error(f"Unknown input type: {input_type}")
            sys.exit(1)

    def _run_file_mode(self, filepath: str):
        """文件模式：读取日志文件"""
        logger.info(f"Reading audit log from: {filepath}")

        if not os.path.exists(filepath):
            logger.error(f"File not found: {filepath}")
            sys.exit(1)

        try:
            with open(filepath, 'r', encoding='utf-8', errors='replace') as f:
                # 跳到文件末尾（只处理新事件）
                f.seek(0, 2)
                logger.info("Waiting for new audit events...")

                while True:
                    # 检查是否需要重新加载规则
                    self.rule_engine.check_and_reload_rules()

                    line = f.readline()
                    if not line:
                        time.sleep(0.5)  # 增加睡眠时间以减少 CPU 占用
                        continue

                    self._process_line(line.strip())

        except KeyboardInterrupt:
            logger.info(f"Stopped by user. Processed {self.event_count} events, generated {self.alert_count} alerts")
        except Exception as e:
            logger.error(f"Error: {e}", exc_info=True)

    def _process_line(self, line: str):
        """处理单行日志"""
        try:
            # 解析事件
            event = self.parser.parse_line(line)
            if not event:
                return

            self.event_count += 1

            # 丰富事件
            event = self.parser.enrich_event(event)

            # 应用规则
            alerts = self.rule_engine.process_event(event)

            # 输出告警
            for alert in alerts:
                self._output_alert(alert)
                self.alert_count += 1

        except Exception as e:
            logger.error(f"Error processing line: {e}, line: {line[:200]}")

    def _output_alert(self, alert: Dict):
        """输出告警"""
        outputs = self.config['engine']['output']

        for output in outputs:
            try:
                output_type = output['type']

                if output_type == 'file':
                    self._output_to_file(alert, output)
                elif output_type == 'syslog' and output.get('enabled', False):
                    self._output_to_syslog(alert, output)
            except Exception as e:
                logger.error(f"Failed to output alert: {e}")

    def _output_to_file(self, alert: Dict, config: Dict):
        """输出到文件"""
        filepath = config['path']
        format_type = config.get('format', 'json')

        # 确保目录存在
        os.makedirs(os.path.dirname(filepath), exist_ok=True)

        try:
            with open(filepath, 'a', encoding='utf-8') as f:
                if format_type == 'json':
                    f.write(json.dumps(alert, ensure_ascii=False) + '\n')
                else:
                    f.write(str(alert) + '\n')

            # 同时输出到控制台
            logger.warning(f"[{alert['severity'].upper()}] {alert['message']}")
        except Exception as e:
            logger.error(f"Failed to write alert to file: {e}")

    def _output_to_syslog(self, alert: Dict, config: Dict):
        """输出到 syslog"""
        try:
            import syslog
            syslog.openlog('sec-auditd')
            syslog.syslog(syslog.LOG_WARNING, json.dumps(alert, ensure_ascii=False))
        except ImportError:
            logger.error("syslog module not available")
        except Exception as e:
            logger.error(f"Failed to send to syslog: {e}")


def main():
    """主函数"""
    if len(sys.argv) < 2:
        print(f"Usage: {sys.argv[0]} <config.yaml>")
        print(f"\nExample:")
        print(f"  {sys.argv[0]} /etc/sec-auditd/alert-engine/config.yaml")
        sys.exit(1)

    config_path = sys.argv[1]

    if not os.path.exists(config_path):
        print(f"Config file not found: {config_path}")
        sys.exit(1)

    try:
        engine = AlertEngine(config_path)
        engine.run()
    except Exception as e:
        logger.error(f"Fatal error: {e}", exc_info=True)
        sys.exit(1)


if __name__ == '__main__':
    main()
