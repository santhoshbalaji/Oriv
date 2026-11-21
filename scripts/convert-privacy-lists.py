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
CNAME_PIN = 'dd5bd59eda209a97efeee1ee7898e119c582a13b'
CNAME_SHA256 = 'f6a241680c4a3e561d4e7566ad67d77d8f0e9969f4dc71a9bf50ae2a1f406b42'
CNAME_FILE = 'combined_disguised_trackers_justdomains.txt'
CNAME_URL_PREFIX = r'^https?://([^/?#@]*@)?'
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

def cosmetic_domain_url(domain):
    host = re.escape(domain).replace(r'\*', '[a-z.]+')
    return r'^https?://([^/]+\.)?' + host + '[:/]'

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
            (no if negative else yes).append(cosmetic_domain_url(domain))
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

def subtract_cosmetic_scope(scope, exception):
    if not exception:
        return None
    key, excluded = next(iter(exception.items()))
    if not scope and key.startswith('if-'):
        return {'unless-' + key[3:]: excluded}
    current_key, included = next(iter(scope.items())) if scope else (None, [])
    if current_key and current_key.startswith('unless-') and key.startswith('if-'):
        if current_key == key.replace('if-', 'unless-', 1):
            return {current_key: sorted(set(included + excluded))}
        # A normal-domain exception and a TLD-wildcard exception for the
        # same selector can share one URL condition.
        common = (included if current_key == 'unless-top-url' else [cosmetic_domain_url(d[1:]) for d in included])
        extra = (excluded if key == 'if-top-url' else [cosmetic_domain_url(d[1:]) for d in excluded])
        return {'unless-top-url': sorted(set(common + extra))}
    if current_key == key == 'if-domain':
        # WebKit has one condition per rule. If an exception is narrower than
        # an included domain, omit this selector for that domain family only.
        def overlaps(left, right):
            left, right = left[1:], right[1:]
            return left == right or left.endswith('.' + right) or right.endswith('.' + left)
        remaining = [domain for domain in included if not any(overlaps(domain, other) for other in excluded)]
        return {'if-domain': remaining} if remaining else None
    # Mixed condition types and negated exceptions may be unrepresentable.
    # Preserve visibility by dropping this selector only.
    return None

def cosmetic_rules(entries, exceptions, light=False):
    by_selector = {}
    for sc, selector in exceptions:
        by_selector.setdefault(selector, []).append(sc)
    grouped = {}
    for sc, selector in entries:
        if light and (sc or not re.fullmatch(r'[.#][a-zA-Z_-][a-zA-Z0-9_-]*', selector)): continue
        for exception in by_selector.get(selector, []):
            sc = subtract_cosmetic_scope(sc, exception)
            if sc is None: break
        if sc is None: continue
        key = json.dumps(sc, sort_keys=True)
        grouped.setdefault(key, []).append(selector)
    result = []
    for key, selectors in sorted(grouped.items()):
        unique = sorted(set(selectors))
        for start in range(0, len(unique), 50):
            result.append({'trigger': {'url-filter': '.*', **json.loads(key)}, 'action': {'type': 'css-display-none', 'selector': ','.join(unique[start:start+50])}})
    return result

def encode(value): return json.dumps(value, ensure_ascii=True, sort_keys=True, separators=(',', ':')).encode() + b'\n'

def cname_rules(text):
    hosts = {line.strip().lower() for line in text.splitlines() if line.strip() and not line.lstrip().startswith('#')}
    if not hosts or any(not DOMAIN.fullmatch(host) or '.' not in host for host in hosts):
        raise ValueError('Unexpected CNAME input')
    parents, covered = set(), set()
    for host in hosts:
        labels = host.split('.')
        for index in range(len(labels) - 1, 0, -1):
            parent = '.'.join(labels[index:])
            if parent in hosts:
                parents.add(parent)
                covered.add(host)
                break
    rules = []
    for host in sorted(hosts - covered):
        prefix = CNAME_URL_PREFIX + (r'([^/:@?#]+\.)?' if host in parents else '')
        # Two fixed endings let WebKit share the host trie. A per-host
        # optional dot forces WebKit to build a separate automaton for each host.
        for suffix in (r'[:/]', r'\.[:/]'):
            rules.append({
                'trigger': {'url-filter': prefix + re.escape(host) + suffix, 'resource-type': RESOURCES},
                'action': {'type': 'block'},
            })
    return rules, {'hosts': len(hosts), 'covered_by_parent': len(covered), 'parent_hosts': len(parents)}

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
    cname_url = f'https://raw.githubusercontent.com/AdguardTeam/cname-trackers/{CNAME_PIN}/data/{CNAME_FILE}'
    cname_path = args.source_dir / CNAME_FILE if args.source_dir else None
    raw = cname_path.read_bytes() if cname_path and cname_path.exists() else fetch(cname_url)
    if hashlib.sha256(raw).hexdigest() != CNAME_SHA256: raise ValueError('Pinned source digest mismatch: cname')
    if cname_path and not cname_path.exists(): cname_path.write_bytes(raw)
    cname, report['cname'] = cname_rules(raw.decode('utf-8'))
    cname_attribution = {'copyright': 'Copyright 2021 Adguard Software Ltd', 'license': 'MIT',
                        'modifications': 'Oriv conversion to WebKit subresource rules with parent-host deduplication'}
    sources['cname'] = {'url': cname_url, 'sha256': CNAME_SHA256, 'bytes': len(raw), **cname_attribution}
    groups = {'network': (blocks, allows), 'cosmetics-light': (cosmetic_rules(cosmetics, exceptions, True), []),
              'cosmetics-strict': (cosmetic_rules(cosmetics, exceptions), []),
              'cookies-network': (b, a), 'cookies-cosmetics': (cosmetic_rules(c, e), []),
              'network-cname': (cname, [])}
    outputs = {}
    for name, (rules, exceptions) in groups.items():
        exceptions = exceptions + [rule for rule in rules if rule['action']['type'] == 'ignore-previous-rules']
        rules = [rule for rule in rules if rule['action']['type'] != 'ignore-previous-rules']
        # Duplicate ALL network exceptions at the end of EVERY chunk. A whitelist
        # in a separate WKContentRuleList would not undo blocking in another list.
        budget = (85_000 if name == 'network-cname' else 140_000) - len(exceptions)
        if budget <= 0: raise ValueError('Too many exceptions')
        chunks = []
        for i in range(0, len(rules), budget):
            value = rules[i:i+budget] + exceptions
            filename = f'{name}-{len(chunks)}.orivrules'
            raw = encode(value)
            header = {'copyright': 'The EasyList authors (https://easylist.to/)', 'license': 'CC-BY-SA-3.0', 'source': 'manifest.json', 'modifications': 'Oriv supported-subset conversion v2' if 'cosmetics' in name else 'Oriv supported-subset conversion v1', 'decodedBytes': len(raw), 'sha256': hashlib.sha256(raw).hexdigest()}
            if name == 'network-cname': header.update(cname_attribution)
            payload = encode(header) + base64.b64encode(zlib.compress(raw, level=9, wbits=-15)) + b'\n'
            write_atomic(destination / filename, payload)
            chunks.append({'file': filename, 'rules': len(value), 'bytes': len(raw), 'bundledBytes': len(payload), 'sha256': hashlib.sha256(raw).hexdigest()})
        outputs[name] = chunks
    manifest = {'rulesVersion': '2026.11.21-' + PIN[:12] + '-' + CNAME_PIN[:12], 'converterVersion': 3, 'upstreamCommit': PIN, 'sources': sources, 'outputs': outputs, 'counts': report,
                'copyright': 'The EasyList authors (https://easylist.to/)', 'license': 'CC-BY-SA-3.0', 'modifications': 'Converted the EasyList network and plain cosmetic subset with scoped exceptions, plus AdGuard CNAME subresource host rules. Grouped and split WebKit rules.'}
    write_atomic(destination / 'manifest.json', json.dumps(manifest, indent=2, sort_keys=True).encode() + b'\n')
    keep = {destination / chunk['file'] for chunks in outputs.values() for chunk in chunks}
    for stale in old_files - keep: stale.unlink()
    print(json.dumps(manifest, indent=2, sort_keys=True))

if __name__ == '__main__': main()
