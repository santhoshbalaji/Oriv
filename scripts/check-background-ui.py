#!/usr/bin/env python3
"""Keep Mac activation/window-raising calls behind the shared background policy."""
from pathlib import Path
import re
import sys

root = Path(__file__).resolve().parent.parent
policy = root / 'Apps/macOS/BackgroundUIMode.swift'
patterns = re.compile(r'\b(?:NSApp|NSApplication\.shared|NSRunningApplication\.current)\.activate\s*\(|\.activateIgnoringOtherApps\s*\(|\.makeKeyAndOrderFront\s*\(|\.orderFrontRegardless\s*\(|\bNS(?:Window|Panel)\s*\(')
violations = []
for folder in ('Apps/macOS', 'Tests/BrowserMacTests', 'Tests/BrowserCompatibilityTests'):
    for path in (root / folder).rglob('*.swift'):
        if path == policy:
            continue
        for number, line in enumerate(path.read_text().splitlines(), 1):
            if patterns.search(line):
                violations.append(f'{path.relative_to(root)}:{number}: bypasses BackgroundUIMode')
if violations:
    print('\n'.join(violations), file=sys.stderr)
    sys.exit(1)
print('Background UI: activation/window raising and window construction are confined to the shared off-screen policy.')
