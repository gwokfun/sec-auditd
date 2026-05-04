#!/usr/bin/env python3
"""
SEC-AUDITD Alert Engine - Python 3.5 Compatible
轻量级告警引擎 - 读取 auditd 事件，应用规则，生成告警
"""

import ast
import io
import os
import sys
import json
import yaml
import time
import re
import logging
import signal
from datetime import datetime, timezone
from collections import defaultdict, deque
from typing import Dict, List, Any, Optional

try:
    from simpleeval import simple_eval, EvalWithCompoundTypes
    HAS_SIMPLEEVAL = True
except ImportError:
    HAS_SIMPLEEVAL = False

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

        event = {}  # type: Dict[str, Any]

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
            logger.debug("Failed to parse line: {}".format(e))

        return None

    @staticmethod
    def decode_audit_value(value: str) -> str:
        """解码 audit 十六进制编码的值"""
        try:
            if not value:
                return value
            # 检查是否为十六进制编码（如 2F62696E2F6C73）
            if AuditParser._looks_like_audit_hex(value):
                try:
                    decoded = bytes.fromhex(value.replace(' ', '')).decode('utf-8', errors='replace')
                    if '\ufffd' not in decoded and (decoded.isprintable() or '\n' in decoded or '\t' in decoded):
                        return decoded
                except (ValueError, UnicodeDecodeError) as e:
                    logger.debug("Failed to decode hex value: {}".format(e))
            return value
        except (ValueError, UnicodeDecodeError) as e:
            logger.debug("Unexpected error decoding value: {}".format(e))
            return value

    @staticmethod
    def _looks_like_audit_hex(value: str) -> bool:
        """判断是否像 auditd 生成的十六进制编码值，避免误解码普通字符串"""
        compact = value.replace(' ', '')
        if len(compact) <= 4 or len(compact) % 2 != 0:
            return False
        return all(c in '0123456789ABCDEFabcdef' for c in compact)

    @staticmethod
    def enrich_event(event: Dict[str, Any]) -> Dict[str, Any]:
        """丰富事件信息"""
        # 添加可读时间
        if 'timestamp' in event:
            try:
                dt = datetime.fromtimestamp(event['timestamp'], tz=timezone.utc)
                event['datetime'] = dt.isoformat().replace('+00:00', 'Z')
            except (ValueError, OSError, OverflowError):
                pass

        # audit PATH 记录常用 name=... 表示文件路径，规则消息统一使用 file
        if 'file' not in event and 'name' in event:
            event['file'] = event['name']

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
        self.alert_cache = {}  # type: Dict
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
            logger.error("Config file not found: {}".format(path))
            sys.exit(1)
        except yaml.YAMLError as e:
            logger.error("Failed to parse config YAML: {}".format(e))
            sys.exit(1)
        except Exception as e:
            logger.error("Failed to load config from {}: {}".format(path, e))
            sys.exit(1)

    def _load_rules(self) -> List[Dict]:
        """加载规则"""
        rules = []  # type: List[Dict]
        rules_dir = self.config['engine']['rules']['dir']

        if not os.path.exists(rules_dir):
            logger.warning("Rules directory not found: {}".format(rules_dir))
            return rules

        seen_rule_ids = set()
        for filename in sorted(os.listdir(rules_dir)):
            if filename.endswith('.yaml') or filename.endswith('.yml'):
                filepath = os.path.join(rules_dir, filename)
                try:
                    with open(filepath, 'r', encoding='utf-8') as f:
                        rule_file = yaml.safe_load(f)
                        if rule_file and 'rules' in rule_file:
                            for rule in rule_file['rules']:
                                rule_id = rule.get('id')
                                if rule_id in seen_rule_ids:
                                    logger.warning(
                                        "Duplicate rule id '{}' in {}; skipping duplicate".format(rule_id, filename)
                                    )
                                    continue
                                if rule_id:
                                    seen_rule_ids.add(rule_id)
                                rules.append(rule)
                            logger.info("Loaded rules from {}".format(filename))
                except yaml.YAMLError as e:
                    logger.error("Failed to parse YAML in {}: {}".format(filename, e))
                except FileNotFoundError:
                    logger.error("Rule file not found: {}".format(filename))
                except Exception as e:
                    logger.error("Failed to load rules from {}: {}".format(filename, e))

        logger.info("Total {} rules loaded".format(len(rules)))
        return rules

    def check_and_reload_rules(self):
        """检查并重新加载规则，同时清理过期的限流缓存"""
        now = time.time()
        if now - self.last_reload > self.reload_interval:
            self._reload_rules(now)

    def reload_rules(self):
        """立即重新加载规则并清理过期限流缓存（可由信号处理器等外部触发器调用）"""
        self._reload_rules(time.time())

    def _reload_rules(self, now: Optional[float] = None):
        """重新加载规则，并清理已删除或不再聚合的规则状态"""
        logger.info("Reloading rules...")
        self.rules = self._load_rules()
        self.last_reload = now if now is not None else time.time()
        self._clean_alert_cache()
        self._clean_aggregate_state()

    def _clean_aggregate_state(self):
        """清理不再属于聚合规则的历史状态，避免热重载后内存持续增长"""
        aggregate_rule_ids = {
            rule.get('id') for rule in self.rules
            if rule.get('id') and 'aggregate' in rule
        }
        stale_rule_ids = [
            rule_id for rule_id in self.state
            if rule_id not in aggregate_rule_ids
        ]
        for rule_id in stale_rule_ids:
            del self.state[rule_id]
        if stale_rule_ids:
            logger.debug("Cleaned aggregate state for removed rules: {}".format(stale_rule_ids))

    def _clean_alert_cache(self):
        """清理过期的限流缓存，防止内存无限增长"""
        throttles = [rule.get('alert', {}).get('throttle', 0) for rule in self.rules]
        max_throttle = max(throttles) if throttles else 3600
        cutoff = time.time() - max_throttle
        expired_keys = [key for key, ts in self.alert_cache.items() if ts < cutoff]
        for key in expired_keys:
            del self.alert_cache[key]
        if expired_keys:
            logger.debug("Cleaned {} expired throttle cache entries".format(len(expired_keys)))

    def process_event(self, event: Dict[str, Any]) -> List[Dict]:
        """处理事件，返回告警列表"""
        alerts = []  # type: List[Dict]

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
                extra_ctx = None  # type: Optional[Dict]
                if 'aggregate' in rule:
                    extra_ctx = self._check_aggregate(event, rule)
                    if extra_ctx is None:
                        continue

                # 生成告警
                alert = self._generate_alert(event, rule, extra_ctx)

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
                logger.debug("Filter evaluation failed: {}".format(e))
                return False

        return True

    def _eval_filter(self, expr: str, event: Dict) -> bool:
        """评估过滤表达式（安全实现）"""
        try:
            # 创建安全的上下文
            context = {}  # type: Dict
            for key, value in event.items():
                if isinstance(value, (str, int, float, bool)):
                    context[key] = value

            # 使用安全的表达式求值
            if HAS_SIMPLEEVAL:
                # 使用 simpleeval 库进行安全求值
                return bool(simple_eval(expr, names=context))
            else:
                # 回退到基于 AST 的安全实现
                logger.warning(
                    "simpleeval not available, using limited AST-based expression evaluation. "
                    "Supported: comparisons (==, !=, <, <=, >, >=), in/not in, and/or/not. "
                    "For full expression support, install: pip install simpleeval"
                )
                return self._safe_eval_fallback(expr, context)
        except (NameError, SyntaxError, ValueError) as e:
            logger.debug("Filter eval error: {}".format(e))
            return False

    def _safe_eval_fallback(self, expr: str, context: Dict) -> bool:
        """安全的回退表达式求值 - 基于 AST 解析，不使用 eval()"""
        try:
            tree = ast.parse(expr, mode='eval')
            return bool(self._eval_ast_node(tree.body, context))
        except (NameError, ValueError, TypeError) as e:
            logger.debug("Fallback eval error for '{}': {}".format(expr, e))
            return False
        except Exception as e:
            logger.debug("Unexpected fallback eval error: {}".format(e))
            return False

    def _eval_ast_node(self, node: ast.AST, context: Dict) -> Any:
        """递归求值 AST 节点（仅支持安全的操作，不允许函数调用或属性访问）"""
        # Python 3.5 support both old and new AST node types
        # Try new style first (Python 3.8+)
        if hasattr(ast, 'Constant') and isinstance(node, ast.Constant):
            return node.value
        # Python 3.5/3.6/3.7 compatibility
        if isinstance(node, ast.Str):
            return node.s
        if isinstance(node, ast.Num):
            return node.n
        if isinstance(node, ast.NameConstant):
            return node.value
        # 变量名：从上下文中查找
        if isinstance(node, ast.Name):
            if node.id in context:
                return context[node.id]
            raise NameError("Unknown variable: {}".format(node.id))
        # 布尔运算（and / or）
        if isinstance(node, ast.BoolOp):
            if isinstance(node.op, ast.And):
                return all(self._eval_ast_node(v, context) for v in node.values)
            if isinstance(node.op, ast.Or):
                return any(self._eval_ast_node(v, context) for v in node.values)
        # 一元运算（not）
        if isinstance(node, ast.UnaryOp) and isinstance(node.op, ast.Not):
            return not self._eval_ast_node(node.operand, context)
        # 比较运算
        if isinstance(node, ast.Compare):
            left = self._eval_ast_node(node.left, context)
            for op, comparator in zip(node.ops, node.comparators):
                right = self._eval_ast_node(comparator, context)
                if isinstance(op, ast.Eq):
                    result = (left == right)
                elif isinstance(op, ast.NotEq):
                    result = (left != right)
                elif isinstance(op, ast.Lt):
                    result = (left < right)
                elif isinstance(op, ast.LtE):
                    result = (left <= right)
                elif isinstance(op, ast.Gt):
                    result = (left > right)
                elif isinstance(op, ast.GtE):
                    result = (left >= right)
                elif isinstance(op, ast.In):
                    result = (left in right)
                elif isinstance(op, ast.NotIn):
                    result = (left not in right)
                else:
                    raise ValueError("Unsupported operator: {}".format(type(op).__name__))
                if not result:
                    return False
                left = right
            return True
        raise ValueError("Unsupported AST node type: {}".format(type(node).__name__))

    def _check_aggregate(self, event: Dict, rule: Dict) -> Optional[Dict]:
        """检查聚合条件，返回 None 表示未触发，返回额外上下文字典表示已触发"""
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

        extra_ctx = {'count': count}  # type: Dict

        if 'unique' in agg:
            # 统计唯一值
            field = agg['unique']
            unique_values = set(str(e.get(field, '')) for _, e in self.state[rule_id][group_key])
            count = len(unique_values)
            extra_ctx['count'] = count
            extra_ctx['unique_count'] = count

        if count >= threshold:
            return extra_ctx
        return None

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

    def _generate_alert(self, event: Dict, rule: Dict, extra_ctx: Optional[Dict] = None) -> Dict:
        """生成告警"""
        alert_config = rule.get('alert', {})
        message = alert_config.get('message', 'Alert triggered')

        # 格式化消息
        try:
            format_ctx = {}  # type: Dict
            for key, value in event.items():
                if isinstance(value, (str, int, float, bool)):
                    format_ctx[key] = value
                else:
                    format_ctx[key] = str(value)
            # 合并聚合上下文（如 count、unique_count）
            if extra_ctx:
                format_ctx.update(extra_ctx)

            message = message.format(**format_ctx)
        except (KeyError, ValueError) as e:
            logger.debug("Message format error: {}".format(e))

        return {
            'timestamp': datetime.now(timezone.utc).isoformat().replace('+00:00', 'Z'),
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
        self._running = True
        self._pending_events = {}
        self._syslog = None
        self._syslog_opened = False
        self._prepare_outputs()
        self._setup_signal_handlers()

    def _prepare_outputs(self):
        """初始化输出目标，避免每条告警重复做固定准备工作"""
        for output in self.config.get('engine', {}).get('output', []):
            if output.get('type') == 'file':
                filepath = output.get('path')
                if filepath:
                    self._ensure_output_dir(filepath)
            elif output.get('type') == 'syslog' and output.get('enabled', False):
                self._ensure_syslog_open()

    def _ensure_output_dir(self, filepath: str):
        """确保输出目录存在"""
        dir_name = os.path.dirname(filepath)
        if not dir_name:
            return
        try:
            os.makedirs(dir_name, exist_ok=True)
        except Exception as e:
            logger.error("Failed to create alert output directory {}: {}".format(dir_name, e))

    def _setup_signal_handlers(self):
        """设置信号处理器"""
        try:
            signal.signal(signal.SIGTERM, self._handle_sigterm)
            signal.signal(signal.SIGHUP, self._handle_sighup)
        except (OSError, ValueError):
            # 在非主线程或某些受限环境中信号处理可能不可用
            logger.debug("Signal handlers could not be set up")

    def _handle_sigterm(self, signum: int, frame: Any) -> None:
        """处理 SIGTERM 信号（优雅退出）"""
        logger.info("Received SIGTERM, shutting down gracefully...")
        self._running = False

    def _handle_sighup(self, signum: int, frame: Any) -> None:
        """处理 SIGHUP 信号（重新加载规则）"""
        logger.info("Received SIGHUP, reloading rules...")
        self.rule_engine.reload_rules()

    def run(self):
        """运行引擎"""
        input_config = self.config['engine']['input']
        input_type = input_config['type']

        logger.info("Starting alert engine in {} mode".format(input_type))

        if input_type == 'file':
            self._run_file_mode(input_config['file'])
        elif input_type == 'audisp':
            logger.error("Audisp mode not yet implemented")
            sys.exit(1)
        else:
            logger.error("Unknown input type: {}".format(input_type))
            sys.exit(1)

    def _run_file_mode(self, filepath: str):
        """文件模式：读取日志文件"""
        logger.info("Reading audit log from: {}".format(filepath))

        if not os.path.exists(filepath):
            logger.error("File not found: {}".format(filepath))
            sys.exit(1)

        f = None
        current_identity = None
        seek_to_end = True
        try:
            while self._running:
                if f is None:
                    f = open(filepath, 'r', encoding='utf-8', errors='replace')
                    if seek_to_end:
                        f.seek(0, 2)
                    current_identity = self._file_identity(filepath)
                    logger.info("Waiting for new audit events...")

                # 检查是否需要重新加载规则
                self.rule_engine.check_and_reload_rules()

                line = f.readline()
                if line:
                    self._process_line(line.strip())
                    continue

                self._flush_pending_events()

                latest_identity = self._file_identity(filepath)
                if latest_identity and latest_identity != current_identity:
                    logger.info("Audit log rotated, reopening: {}".format(filepath))
                    self._close_file(f)
                    f = None
                    current_identity = None
                    seek_to_end = False
                    continue

                time.sleep(0.5)  # 增加睡眠时间以减少 CPU 占用

        except KeyboardInterrupt:
            logger.info("Stopped by keyboard interrupt.")
        except Exception as e:
            logger.error("Error: {}".format(e), exc_info=True)
        finally:
            if f is not None:
                f.close()
            logger.info("Alert engine stopped. Processed {} events, generated {} alerts".format(
                self.event_count, self.alert_count))

    def _close_file(self, f):
        """Best-effort close for log rotation handling."""
        try:
            f.close()
        except Exception as e:
            logger.debug("Failed to close audit log file: {}".format(e))

    def _file_identity(self, filepath: str) -> Optional[tuple]:
        """返回文件身份，用于检测 logrotate 后的 inode 变化"""
        try:
            st = os.stat(filepath)
            return (st.st_dev, st.st_ino)
        except OSError:
            return None

    def _process_line(self, line: str):
        """处理单行日志"""
        try:
            # 解析事件
            event = self.parser.parse_line(line)
            if not event:
                return

            self._flush_pending_events(event.get('serial'))

            event_type = event.get('type')
            serial = event.get('serial')
            if event_type == 'PATH':
                if serial in self._pending_events:
                    event = self._merge_path_event(self._pending_events.pop(serial), event)
                else:
                    return
            elif event_type == 'SYSCALL' and serial and event.get('key'):
                self._pending_events[serial] = event
                return

            self._handle_event(event)

        except Exception as e:
            logger.error("Error processing line: {}, line: {}".format(e, line[:200]))

    def _flush_pending_events(self, current_serial: Optional[str] = None):
        """处理已等待 PATH 记录但可以安全刷出的 SYSCALL 事件"""
        flush_serials = [
            serial for serial in self._pending_events
            if current_serial is None or serial != current_serial
        ]
        for serial in flush_serials:
            event = self._pending_events.pop(serial)
            self._handle_event(event)

    def _merge_path_event(self, event: Dict[str, Any], path_event: Dict[str, Any]) -> Dict[str, Any]:
        """把同 serial 的 PATH 记录补充到原始 SYSCALL 事件中"""
        for key, value in path_event.items():
            if key in ['type', 'timestamp', 'serial']:
                continue
            if key not in event:
                event[key] = value
        if 'name' in path_event:
            event['file'] = path_event['name']
        return event

    def _handle_event(self, event: Dict[str, Any]):
        """丰富、匹配并输出单个完整 audit 事件"""
        self.event_count += 1

        # 丰富事件
        event = self.parser.enrich_event(event)

        # 应用规则
        alerts = self.rule_engine.process_event(event)

        # 输出告警
        for alert in alerts:
            self._output_alert(alert)
            self.alert_count += 1

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
                logger.error("Failed to output alert: {}".format(e))

    def _output_to_file(self, alert: Dict, config: Dict):
        """输出到文件"""
        filepath = config['path']
        format_type = config.get('format', 'json')

        try:
            with self._open_secure_append(filepath) as f:
                if format_type == 'json':
                    f.write(json.dumps(alert, ensure_ascii=False) + '\n')
                else:
                    f.write(str(alert) + '\n')

            # 同时输出到控制台
            logger.warning("[{}] {}".format(alert['severity'].upper(), alert['message']))
        except Exception as e:
            logger.error("Failed to write alert to file: {}".format(e))

    def _open_secure_append(self, filepath: str):
        """以 0600 权限创建并追加告警日志，避免敏感告警全局可读"""
        fd = os.open(filepath, os.O_CREAT | os.O_APPEND | os.O_WRONLY, 0o600)
        try:
            os.fchmod(fd, 0o600)
            return io.open(fd, 'a', encoding='utf-8')
        except Exception:
            os.close(fd)
            raise

    def _output_to_syslog(self, alert: Dict, config: Dict):
        """输出到 syslog"""
        try:
            if not self._ensure_syslog_open():
                return
            self._syslog.syslog(self._syslog.LOG_WARNING, json.dumps(alert, ensure_ascii=False))
        except ImportError:
            logger.error("syslog module not available")
        except Exception as e:
            logger.error("Failed to send to syslog: {}".format(e))

    def _ensure_syslog_open(self) -> bool:
        """按需初始化 syslog，一次 openlog 后复用"""
        if self._syslog_opened:
            return True
        try:
            import syslog
            syslog.openlog('sec-auditd')
            self._syslog = syslog
            self._syslog_opened = True
            return True
        except ImportError:
            logger.error("syslog module not available")
            return False


def main():
    """主函数"""
    if len(sys.argv) < 2:
        print("Usage: {} <config.yaml>".format(sys.argv[0]))
        print("\nExample:")
        print("  {} /etc/sec-auditd/alert-engine/config.yaml".format(sys.argv[0]))
        sys.exit(1)

    config_path = sys.argv[1]

    if not os.path.exists(config_path):
        print("Config file not found: {}".format(config_path))
        sys.exit(1)

    try:
        engine = AlertEngine(config_path)
        engine.run()
    except Exception as e:
        logger.error("Fatal error: {}".format(e), exc_info=True)
        sys.exit(1)


if __name__ == '__main__':
    main()
