#!/usr/bin/env python3
"""Codex transport adapter for the unchanged upstream shunt gates. Fail open."""
import contextlib
import io
import json
import os
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
VENDOR = ROOT / 'vendor'
if not VENDOR.exists():
    VENDOR = ROOT.parent / 'shunt' / 'hooks'
sys.path.insert(0, str(VENDOR))


def main():
    try:
        data = json.load(sys.stdin)
        name = data.get('tool_name', '')
        args = data.get('tool_input') or {}
        if name in ('Bash', 'exec_command', 'shell_command'):
            import check_bash as gate
            args = dict(args)
            args['command'] = args.get('command') or args.get('cmd') or ''
            data['cwd'] = args.get('workdir') or data.get('cwd') or os.getcwd()
        elif name in ('Read', 'read_file'):
            import check_read as gate
            args = dict(args)
            args['file_path'] = args.get('file_path') or args.get('path')
            if args['file_path'] and not os.path.isabs(os.path.expanduser(args['file_path'])):
                args['file_path'] = str(Path(data.get('cwd') or os.getcwd()) / args['file_path'])
        else:
            return
        data['tool_input'] = args
        gate.BULK = str(ROOT / 'scripts' / 'bulk_read.sh')
        stderr = io.StringIO()
        original = sys.stdin
        try:
            sys.stdin = io.StringIO(json.dumps(data))
            with contextlib.redirect_stderr(stderr):
                result = gate.main()
        finally:
            sys.stdin = original
        if result == 2:
            reason = stderr.getvalue().strip().replace(
                'Follow-up questions on the same file cost nothing: run the helper again.',
                'Follow-up questions require another reader call and may incur cost.')
            print(json.dumps({'hookSpecificOutput': {
                'hookEventName': 'PreToolUse', 'permissionDecision': 'deny',
                'permissionDecisionReason': reason}}))
    except Exception:
        # Do not echo event bodies, paths, or commands on unexpected errors.
        pass


if __name__ == '__main__':
    main()
