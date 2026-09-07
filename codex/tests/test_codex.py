import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('reader', ROOT / 'scripts/reader.py')
reader = importlib.util.module_from_spec(spec)
spec.loader.exec_module(reader)


class CodexTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.home = Path(self.tmp.name)
        self.big = self.home / 'big.md'
        self.big.write_text('sample\n' * 900)
        self.small = self.home / 'small.md'
        self.small.write_text('small\n')
        self.cfg = dict(reader.budget.DEFAULT_CONFIG)
        self.cfg['exempt_path_prefixes'] = []
        self.config = self.home / 'config.json'
        self.config.write_text(json.dumps(self.cfg))
        self.env = {'SHUNT_HOME': str(self.home), 'SHUNT_CONFIG_PATH': str(self.config),
                    'SHUNT_LOG_PATH': str(self.home / 'events.jsonl'), 'SHUNT_MODE': '',
                    'SHUNT_TIMEOUT': '', 'SHUNT_MAX_PAYLOAD_BYTES': ''}
        self.patch = patch.dict(os.environ, self.env)
        self.patch.start()
        self.addCleanup(self.patch.stop)

    def gate(self, name='Bash', args=None, session='test', raw=None):
        data = {'tool_name': name, 'tool_input': args or {'command': 'cat big.md'},
                'session_id': session, 'cwd': str(self.home)}
        p = subprocess.run([sys.executable, str(ROOT / 'hooks/pre_tool_use.py')],
                           input=raw if raw is not None else json.dumps(data),
                           capture_output=True, text=True)
        self.assertEqual(p.returncode, 0)
        return json.loads(p.stdout) if p.stdout else {}

    def test_block_transport(self):
        d = self.gate()['hookSpecificOutput']
        self.assertEqual(d['permissionDecision'], 'deny')
        self.assertIn(str(ROOT / 'scripts/bulk_read.sh'), d['permissionDecisionReason'])
        self.assertNotIn('cost nothing', d['permissionDecisionReason'])

    def test_read_and_alias(self):
        for name in ['Read', 'read_file']:
            self.assertTrue(self.gate(name, {'path': 'big.md'}))
        self.assertTrue(self.gate('exec_command', {'cmd': 'cat big.md', 'workdir': str(self.home)}))

    def test_slice_budget_cross_tool(self):
        self.assertFalse(self.gate('Read', {'path': 'big.md', 'limit': 300}))
        self.assertTrue(self.gate(args={'command': 'head -n 100 big.md'}))
        self.assertFalse(self.gate(args={'command': 'head -n 100 big.md'}, session='other'))

    def test_sanction(self):
        self.gate('Read', {'path': 'big.md', 'limit': 350})
        self.assertFalse(self.gate(args={'command': 'bash "%s" "%s" "question"' % (
            ROOT / 'scripts/bulk_read.sh', self.big)}))
        self.assertFalse(self.gate('Read', {'path': 'big.md', 'limit': 350}))

    def test_allow_cases(self):
        for command in ['cat small.md', 'cat missing', 'cat big.md | head -20',
                        'grep sample big.md', 'sed -n "1,20p" big.md']:
            self.assertFalse(self.gate(args={'command': command}))
        self.assertFalse(self.gate(raw='{broken'))
        self.assertFalse(self.gate('unknown'))

    def test_config_off_and_malformed(self):
        self.config.write_text('{broken')
        self.assertFalse(self.gate())
        self.config.write_text(json.dumps(dict(self.cfg, enabled=False)))
        self.assertFalse(self.gate())
        with patch.dict(os.environ, {'SHUNT_MODE': 'on'}):
            self.assertTrue(self.gate())
        with patch.dict(os.environ, {'SHUNT_MODE': 'off'}):
            self.assertFalse(self.gate())

    def test_payload(self):
        prompt, size = reader.payload([self.small], 'question', 500)
        self.assertIn('1: small', prompt)
        self.assertEqual(size, 6)
        with self.assertRaises(reader.ReaderError):
            reader.payload([self.big], 'question', 10)
        self.small.write_bytes(b'\0')
        with self.assertRaises(reader.ReaderError):
            reader.payload([self.small], 'question', 10)

    def test_payload_cap_no_model(self):
        with patch.dict(os.environ, {'SHUNT_MAX_PAYLOAD_BYTES': '2'}), patch.object(reader, 'call') as call:
            with contextlib.redirect_stderr(io.StringIO()):
                self.assertEqual(reader.run([str(self.big), 'question']), 1)
            call.assert_not_called()

    def test_success_tokens_and_unknown_cost(self):
        response = {'choices': [{'message': {'content': '- L1: small'}, 'finish_reason': 'stop'}],
                    'usage': {'prompt_tokens': 100, 'completion_tokens': 10,
                              'prompt_tokens_details': {'cached_tokens': 40}}}
        out = io.StringIO()
        with patch.object(reader, 'call', return_value=response), contextlib.redirect_stdout(out), contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(reader.run([str(self.small), 'question']), 0)
        self.assertIn('in=100 out=10 cost=unknown', out.getvalue())
        events = [json.loads(x) for x in (self.home / 'events.jsonl').read_text().splitlines()]
        self.assertIsNone(events[0]['cost_usd'])
        self.assertEqual(events[1]['event'], 'worker_sanctioned')

    def test_errors_do_not_leak(self):
        err = io.StringIO()
        with patch.object(reader, 'call', side_effect=ValueError('SECRET_TOKEN')), contextlib.redirect_stderr(err):
            self.assertEqual(reader.run([str(self.small), 'question']), 1)
        self.assertNotIn('SECRET_TOKEN', err.getvalue())
        self.assertNotIn('SECRET_TOKEN', (self.home / 'events.jsonl').read_text())

    def test_truncated_answer_rejected(self):
        response = {'choices': [{'message': {'content': '- L1: partial'}, 'finish_reason': 'length'}]}
        with patch.object(reader, 'call', return_value=response), contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(reader.run([str(self.small), 'question']), 1)


if __name__ == '__main__':
    unittest.main(verbosity=2)
