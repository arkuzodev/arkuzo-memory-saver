"""contracts/config-schema.json is the one source for config rules, presets and vault settings.

The Control Center's tables are generated from it (build/bundle.ps1, checked by
Bundle.Tests.ps1). The engine validators, the page and config/defaults.json keep their
own copies, written by hand; these checks hold each of them to the schema.
"""
from pathlib import Path
import importlib.util
import json
import re
import unittest

ROOT = Path(__file__).resolve().parents[2]
SCHEMA = json.loads((ROOT / 'contracts' / 'config-schema.json').read_text(encoding='utf-8'))
ENGINE = (ROOT / 'src' / 'saver' / 'Arkuzo-Memory-Saver.ps1').read_text(encoding='utf-8-sig')
PAGE = (ROOT / 'src' / 'saver' / 'Arkuzo-Control-Center.html').read_text(encoding='utf-8')
DEFAULTS = json.loads((ROOT / 'config' / 'defaults.json').read_text(encoding='utf-8'))
spec = importlib.util.spec_from_file_location('control_center_schema', ROOT / 'src' / 'saver' / 'Arkuzo-Control-Center.py')
cc = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cc)

# Differences that exist on purpose (or are harmless) and are kept as they are.
KNOWN_DIFFERENCES = {
    # The engine caps the stamp at 2^53 - 1 (the largest exact JSON integer), the Control Center at 2^53.
    ('vault', 'arrangeRequestedAtMs', 'max'): (9007199254740991, 9007199254740992),
}


def engine_function(name):
    match = re.search(r'^function ' + re.escape(name) + r'\b.*?^\}', ENGINE, re.S | re.M)
    if not match:
        raise AssertionError(name + ' not found in the engine')
    return match.group(0)


def ps_value(raw):
    raw = raw.strip()
    if raw in ('$true', '$false'):
        return raw == '$true'
    if raw == '$null':
        return None
    if raw.startswith("'"):
        return raw.strip("'")
    return int(raw)


def int_rules(section):
    return {k: (r[1], r[2]) for k, r in SCHEMA['config'][section].items() if r[0] == 'int'}


class GeneratedTablesTests(unittest.TestCase):
    def test_control_center_tables_equal_the_schema(self):
        tupled = lambda rule: tuple(tuple(x) if isinstance(x, list) else x for x in rule)  # noqa: E731
        self.assertEqual(cc.PRESETS, SCHEMA['presets'])
        self.assertEqual({s: {k: tupled(r) for k, r in rules.items()} for s, rules in SCHEMA['config'].items()}, cc.SCHEMA)
        self.assertEqual({k: tupled(r) for k, r in SCHEMA['topLevel'].items()}, cc.TOP_LEVEL)
        self.assertEqual(set(SCHEMA['restartKeys']), cc.RESTART_KEYS)
        self.assertEqual({k: (tupled(v['rule']), v['default']) for k, v in SCHEMA['vault'].items()}, cc.VAULT_SETTINGS)


class EngineTests(unittest.TestCase):
    def test_presets(self):
        body = engine_function('Get-ArkuzoPresets')
        for name, values in SCHEMA['presets'].items():
            block = re.search(r"'" + name + r"' = \[ordered\]@\{(.*?)\n        \}", body, re.S)
            self.assertIsNotNone(block, name + ' missing in the engine')
            for key, value in values.items():
                match = re.search(r'^\s*' + key + r'\s*=\s*(\S+)', block.group(1), re.M)
                self.assertIsNotNone(match, f'{name}.{key} missing in the engine')
                self.assertEqual(ps_value(match.group(1)), value, f'{name}.{key}')
        self.assertEqual(set(re.findall(r"^        '(\w+)' = \[ordered\]", body, re.M)), set(SCHEMA['presets']), 'the same presets')

    def test_health_and_recovery_ranges(self):
        for function, section in (('Get-ArkuzoHealthPolicy', 'health'), ('Get-ArkuzoRestorePolicy', 'recovery')):
            ranges = {k: (int(a), int(b)) for k, a, b in re.findall(r'(\w+)\s*=\s*@\((\d+),\s*(\d+)\)', engine_function(function))}
            self.assertEqual(ranges, int_rules(section), section)

    def test_settings_ranges_and_choices(self):
        body = engine_function('Get-ArkuzoLiveResourceSettings')
        ranges = {k: (int(a), int(b)) for k, a, b in re.findall(r"(\w+)=@\('\w+',(\d+),(\d+)\)", body)}
        self.assertEqual(ranges, int_rules('settings'))
        settings = SCHEMA['config']['settings']
        self.assertIn("-cnotin @(" + ','.join("'" + v + "'" for v in settings['priority'][1]) + ')', body)
        memory = re.findall(r"^\s*'(\w+)' \{ return \[uint32\]\d \}", engine_function('ConvertTo-ArkuzoMemoryPriorityValue'), re.M)
        self.assertEqual(memory, settings['memory_priority'][1])
        # Command-line parameters share the ranges and choices.
        for param, key in (('MaxRamMB', 'target_ram_mb'), ('TrimEverySec', 'trim_every_sec'), ('PollMs', 'poll_ms'), ('CoresPerInstance', 'cores_per_instance')):
            match = re.search(r'\[ValidateRange\((\d+),(\d+)\)\]\[int\]\$' + param + r'\b', ENGINE)
            self.assertEqual((int(match.group(1)), int(match.group(2))), tuple(settings[key][1:]), param)
        for param, key in (('Priority', 'priority'), ('MemoryPriority', 'memory_priority')):
            match = re.search(r'\[ValidateSet\(([^)]*)\)\]\[string\]\$' + param + r'\b', ENGINE)
            self.assertEqual(re.findall(r"'(\w+)'", match.group(1)), settings[key][1], param)
        modes = re.search(r"\[ValidateSet\(([^)]*)\)\]\[string\]\$Mode\b", ENGINE).group(1)
        for preset in SCHEMA['topLevel']['selected_preset'][1]:
            self.assertIn(preset.capitalize(), re.findall(r"'(\w+)'", modes), 'every preset is a -Mode')

    def test_vault_settings(self):
        vault = SCHEMA['vault']
        seen = set()
        for name, args in re.findall(r"Get-ArkuzoVaultSetting \$[\w:]+ '(\w+)' ((?:\$\w+|'[^']*'|\d+)(?: \d+ \d+)?)", ENGINE):
            self.assertIn(name, vault, name + ' is read by the engine but not in the schema')
            parts = args.split(' ')
            rule, default = vault[name]['rule'], vault[name]['default']
            if name != 'sharedPrivateServerId':
                self.assertEqual(ps_value(parts[0]), default, name + ' default')
            if len(parts) == 3:
                self.assertEqual(rule[0], 'int', name)
                for index, which in ((1, 'min'), (2, 'max')):
                    engine, schema = int(parts[index]), rule[index]
                    if engine != schema:
                        self.assertEqual(KNOWN_DIFFERENCES.get(('vault', name, which)), (engine, schema), f'{name} {which}')
            seen.add(name)
        for name, default, values in re.findall(r"& \$enum '(\w+)' '([^']*)' @\(([^)]*)\)", ENGINE):
            self.assertEqual(vault[name]['rule'], ['enum', re.findall(r"'([^']*)'", values)], name)
            self.assertEqual(vault[name]['default'], default, name + ' default')
            seen.add(name)
        self.assertGreaterEqual(len(seen), 18, 'the engine reads the vault settings')


class PageTests(unittest.TestCase):
    def test_preset_cards(self):
        info = re.search(r'^const PRESET_INFO = \{(.*)\};$', PAGE, re.M).group(1)
        cards = dict(re.findall(r"(\w+): \['\w+', '([^']*)'\]", info))
        self.assertEqual(set(cards), set(SCHEMA['presets']))
        for name, subtitle in cards.items():
            preset = SCHEMA['presets'][name]
            self.assertIn(f"{preset['target_ram_mb']} MB", subtitle, name)
            self.assertRegex(subtitle, r'\b' + str(preset['cores_per_instance']) + r' cores?\b', name)

    def test_farm_and_layout_fields(self):
        checked = 0
        for table in ('FARM_FIELDS', 'LAYOUT_FIELDS'):
            body = re.search(r'^const ' + table + r' = \[\n(.*?)\n\];$', PAGE, re.S | re.M).group(1)
            for line in body.split('\n'):
                name = re.match(r"\s*\['(\w+)'", line).group(1)
                rule = SCHEMA['config']['accounts'][name] if name == 'provider' else SCHEMA['vault'][name]['rule']
                number = re.search(r"\['int', (\d+), (\d+),", line)
                choice = re.search(r"\['enum', \[([^\]]*)\]", line)
                if number:
                    self.assertEqual(['int', int(number.group(1)), int(number.group(2))], rule, name)
                elif choice:
                    self.assertEqual(['enum', re.findall(r"'([^']*)'", choice.group(1))], rule, name)
                elif "['bool']" in line:
                    self.assertEqual(['bool'], rule, name)
                else:
                    self.assertIn("['monitor']", line, name)
                    self.assertEqual(rule[0], 'int', name)
                checked += 1
        self.assertGreaterEqual(checked, 15)


class DefaultsTests(unittest.TestCase):
    def test_shipped_defaults_follow_the_schema(self):
        self.assertIn(DEFAULTS['selected_preset'], SCHEMA['topLevel']['selected_preset'][1])
        self.assertIsInstance(DEFAULTS['config_lock'], bool)
        extra = {'recovery': {'excluded_account_ids'}}
        for section in ('settings', 'health', 'recovery'):
            rules = SCHEMA['config'][section]
            self.assertEqual(set(DEFAULTS[section]) - extra.get(section, set()), set(rules), section + ': every setting, nothing unknown')
            for key, value in DEFAULTS[section].items():
                if key in rules:
                    self.assertEqual(cc.validate_value(tuple(tuple(x) if isinstance(x, list) else x for x in rules[key]), value, key), value, f'{section}.{key}')


if __name__ == '__main__':
    unittest.main()
