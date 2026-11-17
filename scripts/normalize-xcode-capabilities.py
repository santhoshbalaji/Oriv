#!/usr/bin/env python3
"""Repair XcodeGen 2.46's nested TargetAttributes serialization (upstream #1637).

project.yml remains the source of capability values. Newer generators already
write dictionaries; those projects pass through byte-for-byte unchanged.
"""
from pathlib import Path
import json
import re


def normalize(text: str) -> str:
    def replace(match: re.Match) -> str:
        indent, quoted = match.groups()
        swift_dictionary = json.loads(quoted)
        # Capability metadata consists only of nested dictionaries and integer flags.
        values = json.loads(swift_dictionary.replace('[', '{').replace(']', '}'))
        if not isinstance(values, dict) or not all(
            re.fullmatch(r'com\.apple\.[A-Za-z0-9.-]+', key)
            and isinstance(value, dict) and set(value) == {'enabled'}
            and type(value['enabled']) is int and value['enabled'] in (0, 1)
            for key, value in values.items()
        ):
            raise ValueError('Unexpected SystemCapabilities structure; refusing to guess')
        lines = [f'{indent}SystemCapabilities = {{']
        for key, value in sorted(values.items()):
            lines += [f'{indent}\t{key} = {{', f'{indent}\t\tenabled = {value["enabled"]};', f'{indent}\t}};']
        lines.append(f'{indent}}};')
        return '\n'.join(lines)

    return re.sub(r'(?m)^([\t ]*)SystemCapabilities = ("(?:\\.|[^"\\])*");$', replace, text)


if __name__ == '__main__':
    path = Path(__file__).resolve().parents[1] / 'PersonalBrowser.xcodeproj/project.pbxproj'
    original = path.read_text()
    result = normalize(original)
    if result != original:
        path.write_text(result)
