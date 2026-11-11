#!/usr/bin/env python3
"""Original, deliberately bounded ABP -> WebKit converter (MIT).

Fetches only immutable upstream commits when explicitly run by a maintainer.
Generated adaptations: CC BY-SA 3.0; see Resources/Privacy/NOTICE.txt.
No executable/procedural syntax, regex filters, document blocking or remote includes.
"""
import argparse
import base64
import zlib
from collections import Counter
import hashlib
import json
from pathlib import Path
import re
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'Packages/BrowserKit/Sources/BrowserEngine/Resources/Privacy'
PIN = '74c3e769a009be43c1bb73b0744e5e6e8943bad3'
SOURCE_PIN = '0476c21b10d796a3fd533cf2584ebf133ede36a5'
TYPES = {'script': 'script', 'image': 'image', 'stylesheet': 'style-sheet', 'font': 'font', 'media': 'media', 'xmlhttprequest': 'raw', 'subdocument': 'child-document', 'ping': 'ping', 'websocket': 'websocket', 'other': 'other'}
# `fetch` and `raw` are distinct on recent WebKit. Never filter a main document.
RESOURCES = sorted(set(TYPES.values()) | {'fetch', 'svg-document'})
DOMAIN = re.compile(r'^[a-z0-9_-]+(?:\.[a-z0-9_-]+)*$')

def scope(domains):
    yes, no = [], []
    for d in domains:
        negative = d.startswith('~')
        d = d.lstrip('~').lower()
        if not DOMAIN.fullmatch(d):
            raise ValueError('unsupported-domain')
        (no if negative else yes).append('*' + d)
    if yes and no:
        raise ValueError('mixed-domain-scope') # WebKit disallows both in one trigger.
    return {'if-domain': sorted(set(yes))} if yes else {'unless-domain': sorted(set(no))} if no else {}

def cosmetic_scope(domains):
    # TLD wildcard exceptions are allowed conservatively across suffixes rather
    # than dropping an upstream exception (e.g. sony.*). No procedural syntax.
    try: return scope(domains)
    except ValueError:
        yes, no = [], []
        for domain in domains:
            negative = domain.startswith('~')
            domain = domain.lstrip('~').lower()
            if not re.fullmatch(r'[a-z0-9_-]+(?:\.[a-z0-9_-]+)*(?:\.\*)?', domain): raise
            host = re.escape(domain).replace(r'\*', '[a-z.]+')
            (no if negative else yes).append('^https?://([^/]+\\.)?' + host + '[:/]')
        if yes and no: raise ValueError('mixed-domain-scope')
        return {'if-top-url': sorted(set(yes))} if yes else {'unless-top-url': sorted(set(no))}

def url_regex(pattern):
    if not pattern or pattern.startswith('/') and pattern.endswith('/'):
        raise ValueError('regex-or-empty')
    domain_anchor = pattern.startswith('||')
    start = pattern.startswith('|')
    end = pattern.endswith('|')
    body = pattern[2:] if domain_anchor else pattern[1:] if start else pattern
    body = body[:-1] if end else body
    if any(ord(c) > 127 or c in '{}[]\\' for c in body):
        raise ValueError('unsupported-url-pattern')
    encoded = ''.join('.*' if c == '*' else r'[^a-zA-Z0-9_.%-]' if c == '^' else re.escape(c) for c in body)
    return ('^https?://([^/]+\\.)?' if domain_anchor else '^' if start else '') + encoded + ('$' if end else '')

def network(line):
    allow = line.startswith('@@')
    if allow: line = line[2:]
    pattern, sep, options = line.partition('$')
    trigger = {'url-filter': url_regex(pattern), 'resource-type': RESOURCES.copy()}
    positive, negative = set(), set()
    for opt in options.split(',') if sep else []:
        if opt.startswith('domain='):
            trigger.update(scope(opt[7:].split('|')))
        elif opt in ('third-party', '~third-party'):
            trigger['load-type'] = ['third-party' if opt == 'third-party' else 'first-party']
        elif opt == 'match-case': trigger['url-filter-is-case-sensitive'] = True
        elif opt in TYPES: positive.add(TYPES[opt])
        elif opt.startswith('~') and opt[1:] in TYPES: negative.add(TYPES[opt[1:]])
        else: raise ValueError('unsupported-option:' + opt.split('=')[0])
    types = (positive or set(RESOURCES)) - negative
    if 'raw' in types and 'raw' in positive: types.add('fetch')
    if 'raw' in negative: types.discard('fetch')
    if not types: raise ValueError('empty-resource-types')
    trigger['resource-type'] = sorted(types)
    return {'trigger': trigger, 'action': {'type': 'ignore-previous-rules' if allow else 'block'}}

def parse(text):
    counts = Counter()
    blocks, allows, cosmetics, cosmetic_exceptions = [], [], [], []
    lines = text.splitlines()
    disabled = {x.removesuffix(',badfilter').removesuffix('$badfilter') for x in lines if x.endswith((',badfilter', '$badfilter'))}
    for line in lines:
        line = line.strip()
        counts['input_lines'] += 1
        if not line or line.startswith(('!', '[Adblock')):
            counts['metadata'] += 1; continue
        if line in disabled or line.endswith((',badfilter', '$badfilter')):
            counts['dropped:badfilter'] += 1; continue
        try:
            if '#@#' in line or '##' in line:
                marker = '#@#' if '#@#' in line else '##'
                domains, selector = line.split(marker, 1)
                # Excludes procedural selectors, style injection and scriptlets.
                if not selector or any(x in selector for x in [':has(', ':has-text(', ':matches-', ':xpath(', ':upward(', ':remove(', ':style(', '+js(', '{', '}', '\\', ':-abp-', ':contains(']):
                    raise ValueError('advanced-cosmetic')
                sc = cosmetic_scope(domains.split(',')) if domains else {}
                (cosmetic_exceptions if marker == '#@#' else cosmetics).append((sc, selector))
                counts['cosmetic_exception' if marker == '#@#' else 'cosmetic'] += 1
            elif any(x in line for x in ['#?#', '#$#', '#%#', '#@$#', '#@?#']):
                raise ValueError('advanced-cosmetic')
            else:
                rule = network(line)
                target = allows if rule['action']['type'] == 'ignore-previous-rules' else blocks
                target.append(rule)
                # WebKit has no regex disjunction. Preserve ABP's terminal separator
                # OR end-of-URL by a second rule, including whitelist variants.
                pattern = line.removeprefix('@@').partition('$')[0]
                if pattern.endswith('^'):
                    end_rule = json.loads(json.dumps(rule))
                    end_rule['trigger']['url-filter'] = rule['trigger']['url-filter'].removesuffix(r'[^a-zA-Z0-9_.%-]') + '$'
                    target.append(end_rule)
                counts['network_exception' if line.startswith('@@') else 'network'] += 1
        except ValueError as error:
            counts['dropped:' + str(error)] += 1
    return blocks, allows, cosmetics, cosmetic_exceptions, counts

def cosmetic_rules(entries, exceptions, light=False):
    # Global cosmetic exceptions suppress their selector; scoped exceptions below
    # conservatively preserve all visible content on the affected sites.
    excluded = {selector for sc, selector in exceptions if not sc}
    grouped = {}
    for sc, selector in entries:
        if selector in excluded: continue
        if light and (sc or not re.fullmatch(r'[.#][a-zA-Z_-][a-zA-Z0-9_-]*', selector)): continue
        key = json.dumps(sc, sort_keys=True)
        grouped.setdefault(key, []).append(selector)
    result = []
    for key, selectors in sorted(grouped.items()):
        unique = sorted(set(selectors))
        for start in range(0, len(unique), 50):
            result.append({'trigger': {'url-filter': '.*', **json.loads(key)}, 'action': {'type': 'css-display-none', 'selector': ','.join(unique[start:start+50])}})
    # WebKit cannot undo just one CSS selector. Scoped cosmetic exceptions
    # conservatively allow ALL cosmetics on their domains, preserving upstream
    # visibility at the expense of some hiding. They never disable network rules.
    for key in sorted({json.dumps(sc, sort_keys=True) for sc, _ in exceptions if sc}):
        result.append({'trigger': {'url-filter': '.*', **json.loads(key)}, 'action': {'type': 'ignore-previous-rules'}})
    return result

def encode(value): return json.dumps(value, ensure_ascii=True, sort_keys=True, separators=(',', ':')).encode() + b'\n'

def write_atomic(path, data):
    temporary = path.with_suffix(path.suffix + '.tmp')
    temporary.write_bytes(data)
    temporary.replace(path)

def fetch(url):
    with urllib.request.urlopen(url, timeout=60) as response: return response.read()

def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--output-dir', type=Path, default=OUT, help='separate destination for reproducibility checks')
    ap.add_argument('--source-dir', type=Path, help='offline source cache; missing files are fetched from pinned URLs')
    args = ap.parse_args()
    destination = args.output_dir
    destination.mkdir(parents=True, exist_ok=True)
    old_files = set(destination.glob('*.orivrules'))
    sources, report, parsed = {}, {}, {}
    for name, file in [('easylist', 'easylist.txt'), ('easyprivacy', 'easyprivacy.txt'), ('cookies', 'easylist-cookie.txt')]:
        url = f'https://raw.githubusercontent.com/easylist/easylist/{PIN}/{file}' if name != 'cookies' else f'https://raw.githubusercontent.com/easylist/easylist/{SOURCE_PIN}/easylist-cookie.template'
        path = args.source_dir / file if args.source_dir else None
        if path and path.exists(): raw = path.read_bytes()
        elif name == 'cookies':
            template = fetch(url).decode()
            def include(match):
                resource = match[1]
                if not re.fullmatch(r'[a-zA-Z0-9_./-]+', resource) or '..' in resource: raise ValueError('Unsafe include')
                return fetch(f'https://raw.githubusercontent.com/easylist/easylist/{SOURCE_PIN}/{resource}').decode()
            raw = re.sub(r'%include easylist:([^%]+)%', include, template).encode()
            if b'%include' in raw: raise ValueError('Unresolved include')
        else: raw = fetch(url)
        if path and not path.exists(): path.write_bytes(raw)
        expected = {'easylist': '05b0b49b60fcb9de2c988694603f5f0d8aaf4717ea0574bb00548531fa934d79', 'easyprivacy': 'a18dfcc15dcdbc6fd1c8f5cb0366064380df92ae8e6aed8c6ed803770ed55244', 'cookies': '91ec6cdbd4a55f49f45ca3d51d6b0c4435e0ab91068f197fd8ce9f571ca82297'}
        if hashlib.sha256(raw).hexdigest() != expected[name]: raise ValueError('Pinned source digest mismatch: ' + name)
        sources[name] = {'url': url, 'sha256': hashlib.sha256(raw).hexdigest(), 'bytes': len(raw)}
        parsed[name] = parse(raw.decode('utf-8'))
        report[name] = dict(sorted(parsed[name][-1].items()))
    blocks, allows, cosmetics, exceptions = [], [], [], []
    for name in ['easylist', 'easyprivacy']:
        b, a, c, e, _ = parsed[name]
        blocks += b; allows += a; cosmetics += c; exceptions += e
    b, a, c, e, _ = parsed['cookies']
    groups = {'network': (blocks, allows), 'cosmetics-light': (cosmetic_rules(cosmetics, exceptions, True), []),
              'cosmetics-strict': (cosmetic_rules(cosmetics, exceptions), []),
              'cookies-network': (b, a), 'cookies-cosmetics': (cosmetic_rules(c, e), [])}
    outputs = {}
    for name, (rules, exceptions) in groups.items():
        exceptions = exceptions + [rule for rule in rules if rule['action']['type'] == 'ignore-previous-rules']
        rules = [rule for rule in rules if rule['action']['type'] != 'ignore-previous-rules']
        # Duplicate ALL network exceptions at the end of EVERY chunk. A whitelist
        # in a separate WKContentRuleList would not undo blocking in another list.
        budget = 140_000 - len(exceptions)
        if budget <= 0: raise ValueError('Too many exceptions')
        chunks = []
        for i in range(0, len(rules), budget):
            value = rules[i:i+budget] + exceptions
            filename = f'{name}-{len(chunks)}.orivrules'
            raw = encode(value)
            header = {'copyright': 'The EasyList authors (https://easylist.to/)', 'license': 'CC-BY-SA-3.0', 'source': 'manifest.json', 'modifications': 'Oriv supported-subset conversion v1', 'decodedBytes': len(raw), 'sha256': hashlib.sha256(raw).hexdigest()}
            payload = encode(header) + base64.b64encode(zlib.compress(raw, level=9, wbits=-15)) + b'\n'
            write_atomic(destination / filename, payload)
            chunks.append({'file': filename, 'rules': len(value), 'bytes': len(raw), 'bundledBytes': len(payload), 'sha256': hashlib.sha256(raw).hexdigest()})
        outputs[name] = chunks
    manifest = {'rulesVersion': '2026.11.11-' + PIN[:12], 'converterVersion': 1, 'upstreamCommit': PIN, 'sources': sources, 'outputs': outputs, 'counts': report,
                'copyright': 'The EasyList authors (https://easylist.to/)', 'license': 'CC-BY-SA-3.0', 'modifications': 'Converted supported network and plain cosmetic subset; unsupported syntax dropped; scoped cosmetic exceptions conservatively allow all cosmetics; grouped/split WebKit rules.'}
    write_atomic(destination / 'manifest.json', json.dumps(manifest, indent=2, sort_keys=True).encode() + b'\n')
    keep = {destination / chunk['file'] for chunks in outputs.values() for chunk in chunks}
    for stale in old_files - keep: stale.unlink()
    print(json.dumps(manifest, indent=2, sort_keys=True))

if __name__ == '__main__': main()
