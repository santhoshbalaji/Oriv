#!/usr/bin/env python3
"""Cap raw design choices per source file and require retired UI copy to stay removed."""
import argparse
from collections import Counter
import json
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parent.parent
BASELINE = ROOT / "scripts/design-token-baseline.json"
DEFINITIONS = {"Theme.swift", "VisualSnapshots.swift", "ChromeVisualFixture.swift",
               "SpeedometerBenchmark.swift", "SyncTimingProbe.swift", "BackgroundUIMode.swift"}
RULES = {
    "font size": r"\.system\(size:\s*\d"
                 r"|\bNSFont\.\w+\(ofSize:\s*\d",
    "font style": r"\.font\(\.(?:largeTitle|title[23]?|headline|subheadline|body|callout|footnote|caption2?)\b",
    "radius": r"(?:cornerRadius|[xy]Radius):\s*\d",
    "padding": r"\.padding\((?:\.[a-zA-Z]+,\s*|\[[^\]]*\],\s*)?\d[\d.]*\)",
    "spacing": r"spacing:\s*\d",
    "raw color": r"(?<![\w.])(?:Color|NSColor|UIColor)\.(?!self\b)\w+"
                 r"|\bTheme\.hex\(0x[0-9a-fA-F]+"
                 r"|\bColor\((?:\.sRGB(?:Linear)?,\s*)?(?:red|white|hue):"
                 r"|\.foregroundStyle\(\.(?:secondary|tertiary|primary|quaternary|red|green|orange|yellow|blue|purple|white|black|tint)\b",
    "focus state": r"\.focusEffectDisabled\(\)|\.focusRingType\s*=\s*\.none"
                   r"|\bNSFocusRingPlacement\b|\.setFocusRingStyle\(",
    "shadow": r"\.shadow\(",
    "motion": r"\.(?:easeInOut|easeOut|easeIn|linear|spring|snappy|smooth|bouncy|interactiveSpring)\(",
    "retired copy": r'"(?:[^"\\]*\b(?:colour|colours|acknowledgements|Mac & iPhone|Other Devices|T3 Code|Browser sync|Sync with iCloud|iCloud continuity|'
                    r'Search or enter website|Search or address|Page could not load|developer account)\b|Lists:)',
}
RULES = {name: re.compile(pattern) for name, pattern in RULES.items()}


def scan(root):
    counts = {}
    for source in sorted((root / "Apps").rglob("*.swift")):
        if source.name in DEFINITIONS:
            continue
        found = Counter()
        for line in source.read_text().splitlines():
            if line.lstrip().startswith("//"):
                continue
            code, _, comment = line.partition("// oriv:raw-metric ")
            for name, rule in RULES.items():
                if comment.strip() and name in {"font size", "font style", "radius", "padding", "spacing"}:
                    continue
                found[name] += len(rule.findall(code))
        if +found:
            counts[source.relative_to(root).as_posix()] = dict(+found)
    return counts


def totals(files):
    result = Counter()
    for counts in files.values():
        result.update(counts)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--report", action="store_true", help="print counts by file as JSON")
    args = parser.parse_args()
    current = scan(ROOT)
    if args.report:
        print(json.dumps(current, indent=2, sort_keys=True))
        return 0
    baseline = json.loads(BASELINE.read_text())
    failures = []
    for file, counts in current.items():
        for name, count in counts.items():
            maximum = baseline.get(file, {}).get(name, 0)
            if count > maximum:
                failures.append(f"{file}: {name} {count} exceeds baseline {maximum}")
    used, cap = totals(current), totals(baseline)
    for name in RULES:
        print(f"{name}: {used[name]}/{cap[name]}")
    if failures:
        print("\n".join(failures), file=sys.stderr)
    return bool(failures)


if __name__ == "__main__":
    sys.exit(main())
