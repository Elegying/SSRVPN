"""Behavioural regressions for hard rules on the lightweight docs CI path."""
from pathlib import Path
import tempfile
import unittest

from scripts.check_doc_consistency import validate


RULES_PATH = 'docs/PRODUCT_REQUIREMENTS.zh-CN.md'
RULES = '# Hard rules\n\n' + ''.join(f'{n}. Rule {n}\n' for n in range(1, 58)) + (
    '\n国旗补充要求：keep the selected exit.\n\n## 规则变更流程\n\n'
    + ''.join(f'{n}. Change step {n}\n' for n in range(1, 6))
)


class HardRuleDocumentationTests(unittest.TestCase):
    def check(self, documents):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for name, body in {RULES_PATH: RULES, **documents}.items():
                path = root / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(body, encoding='utf-8')
            return validate(root, list(documents))

    def test_accepts_numbered_rules_and_separate_change_steps(self):
        self.assertEqual(self.check({RULES_PATH: RULES}), [])

    def test_docs_guard_rejects_duplicate_missing_reordered_or_empty_rules(self):
        for rules in (
            RULES.replace('\n2. Rule 2\n', '\n1. Rule 2\n'),
            RULES.replace('\n2. Rule 2\n', '\n'),
            RULES.replace('1. Rule 1\n2. Rule 2', '2. Rule 2\n1. Rule 1'),
            '# Rules\n\n## 规则变更流程\n1. Change\n',
            RULES.replace('## 规则变更流程', '## Missing boundary'),
        ):
            with self.subTest(rules=rules[:100]):
                self.assertTrue(self.check({RULES_PATH: rules}))

    def test_fenced_examples_do_not_change_rule_numbering(self):
        example = '```text\n1. Example, not a requirement\n```\n'
        self.assertEqual(self.check({RULES_PATH: RULES.replace('\n国旗', '\n' + example + '国旗')}), [])

    def test_pr_template_rejects_obsolete_product_constraints(self):
        name = '.github/PULL_REQUEST_TEMPLATE.md'
        for old in ('IPv4-only 路由和两页产品结构保持不变。',
                    '双栈、三页；IPv4-only 路由保持不变。',
                    '双栈、三页；`两页产品结构`保持不变。'):
            with self.subTest(old=old):
                self.assertTrue(self.check({name: old}))
        self.assertEqual(self.check({name: '双栈路由和三页产品结构保持不变。'}), [])

    def test_pr_template_allows_explicitly_forbidding_the_old_baseline(self):
        name = '.github/PULL_REQUEST_TEMPLATE.md'
        for text in (
            '保持双栈、三页；不得恢复 IPv4-only 路由和两页产品结构。',
            '保持双栈、三页；禁止回退到两页产品结构，也不得采用 IPv4-only 路由。',
        ):
            with self.subTest(text=text):
                self.assertEqual(self.check({name: text}), [])
        for text in (
            '保持双栈、三页；不得改变 IPv4-only 路由和两页产品结构。',
            '保持双栈、三页；不得恢复 IPv4-only 路由，但两页产品结构保持不变。',
        ):
            with self.subTest(text=text):
                self.assertTrue(self.check({name: text}))

    def test_health_rejects_stale_count_and_unqualified_third_party_claim(self):
        name = 'docs/PROJECT_HEALTH.md'
        for old in ('硬性规则清单已修正为 1..56 连续。',
                    '第三方代理／VPN 软件不受影响。'):
            with self.subTest(old=old):
                self.assertTrue(self.check({name: '# Health\n\n## 当前修复\n' + old}))
        current = ('# Health\n\n## 当前修复\n硬性规则清单为 1..57 连续。\n'
                   '外来代理设置原样保留；安装器会结束其他目录中同名 mihomo.exe。\n')
        self.assertEqual(self.check({name: current}), [])

    def test_historical_sections_and_superseded_adrs_remain_readable(self):
        old = '第三方代理／VPN 软件不受影响。硬性规则清单为 1..56 连续。'
        health = '# Health\n\n## 当前修复\n外来代理设置原样保留。\n\n## 历史版本\n' + old
        self.assertEqual(self.check({'docs/PROJECT_HEALTH.md': health}), [])
        self.assertEqual(self.check({'docs/decisions/old.md': '历史 IPv4-only 路由和两页产品结构。'}), [])


if __name__ == '__main__':
    unittest.main()
