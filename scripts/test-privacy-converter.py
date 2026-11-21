#!/usr/bin/env python3
import base64
import importlib.util
import json
import re
from pathlib import Path
import unittest
import zlib
spec = importlib.util.spec_from_file_location('converter', Path(__file__).with_name('convert-privacy-lists.py'))
c = importlib.util.module_from_spec(spec); spec.loader.exec_module(c)

class ConversionTests(unittest.TestCase):
    def test_supported_network_and_exceptions(self):
        blocks, allows, _, _, counts = c.parse('||ads.example^$script,third-party\n@@||ads.example/needed.js$script\n')
        self.assertEqual(counts, {'input_lines': 2, 'network': 1, 'network_exception': 1})
        self.assertEqual(blocks[0]['trigger']['load-type'], ['third-party'])
        self.assertEqual(allows[0]['action']['type'], 'ignore-previous-rules')
        self.assertNotIn('document', blocks[0]['trigger']['resource-type'])
    def test_drop_categories_count_every_line(self):
        parsed = c.parse('! comment\n||x.example^$redirect=foo\n/regex.*/\nx.example#?#div:has-text(ad)\nx.example##.ad\nx.example#@#.ad\n')
        counts = parsed[-1]
        self.assertEqual(sum(v for k,v in counts.items() if k != 'input_lines'), counts['input_lines'])
        self.assertEqual(counts['dropped:unsupported-option:redirect'], 1)
        self.assertEqual(c.cosmetic_rules(parsed[2], parsed[3]), [])
    def test_domain_scope_and_badfilter(self):
        self.assertEqual(c.scope(['example.com']), {'if-domain':['*example.com']})
        with self.assertRaises(ValueError): c.scope(['example.com','~sub.example.com'])
        self.assertEqual(c.parse('||x.example^$script\n||x.example^$script,badfilter\n')[-1], {'input_lines':2,'dropped:badfilter':2})
    def test_balanced_cosmetics_are_simple_generic_selectors(self):
        entries=[({},'.ad'), ({'if-domain':['*example.com']}, '#banner'), ({}, 'div > .ad')]
        rules=c.cosmetic_rules(entries, [], True)
        self.assertEqual(len(rules),1); self.assertEqual(rules[0]['action']['selector'],'.ad')
    def test_scoped_exception_only_changes_its_own_selector(self):
        _, _, entries, exceptions, _ = c.parse(
            '##.ad\n##.banner\nwww.example.com,elsewhere.test##.promo\n'
            'example.com#@#.ad\nexample.com#@#.promo\n'
        )
        rules = c.cosmetic_rules(entries, exceptions)
        by_selector = {rule['action']['selector']: rule['trigger'] for rule in rules}
        self.assertEqual(by_selector['.ad'], {'url-filter': '.*', 'unless-domain': ['*example.com']})
        self.assertEqual(by_selector['.banner'], {'url-filter': '.*'})
        self.assertEqual(by_selector['.promo'], {'url-filter': '.*', 'if-domain': ['*elsewhere.test']})
        self.assertTrue(all(rule['action']['type'] == 'css-display-none' for rule in rules))

    def test_mixed_exception_patterns_keep_unrelated_sites(self):
        _, _, entries, exceptions, _ = c.parse(
            '###cookie\nexample.com#@##cookie\nexample.*#@##cookie\n'
        )
        rule, = c.cosmetic_rules(entries, exceptions)
        self.assertEqual(rule['trigger'], {
            'url-filter': '.*',
            'unless-top-url': sorted([c.cosmetic_domain_url('example.com'), c.cosmetic_domain_url('example.*')]),
        })

    def test_bundle_headers_digests_and_counts(self):
        import hashlib
        manifest=json.loads((c.OUT/'manifest.json').read_text())
        for name, counts in manifest['counts'].items():
            if name == 'cname': continue
            self.assertEqual(sum(v for k,v in counts.items() if k != 'input_lines'),counts['input_lines'],name)
        for components in manifest['outputs'].values():
            for component in components:
                header,payload=(c.OUT/component['file']).read_bytes().split(b'\n',1)
                header=json.loads(header)
                self.assertEqual(header['license'], 'MIT' if component['file'].startswith('network-cname-') else 'CC-BY-SA-3.0')
                raw=zlib.decompress(base64.b64decode(payload), wbits=-15)
                self.assertEqual(len(raw),header['decodedBytes'])
                self.assertEqual(hashlib.sha256(raw).hexdigest(),component['sha256'])
                rules=json.loads(raw); self.assertEqual(len(rules),component['rules']); self.assertLess(len(rules),150000)
                seen_allow=False
                for rule in rules:
                    if rule['action']['type']=='ignore-previous-rules': seen_allow=True
                    else: self.assertFalse(seen_allow)

    def test_bundled_cname_hosts_are_blocked_only_as_subresources(self):
        manifest = json.loads((c.OUT/'manifest.json').read_text())
        chunks = manifest['outputs']['network-cname']
        counts = manifest['counts']['cname']
        self.assertEqual(sum(chunk['rules'] for chunk in chunks), 2 * (counts['hosts'] - counts['covered_by_parent']))
        samples = {'analytics.sixt.com', 'analytics.seagate.com'}
        found = set()
        for chunk in chunks:
            _, payload = (c.OUT/chunk['file']).read_bytes().split(b'\n', 1)
            for rule in json.loads(zlib.decompress(base64.b64decode(payload), wbits=-15)):
                trigger = rule['trigger']
                self.assertNotIn('document', trigger['resource-type'])
                self.assertNotIn('load-type', trigger)
                for host in samples:
                    exact = c.CNAME_URL_PREFIX + re.escape(host)
                    if trigger['url-filter'] not in {exact + r'[:/]', exact + r'\.[:/]'}: continue
                    dotted = trigger['url-filter'].endswith(r'\.[:/]')
                    found.add((host, dotted))
                    url_filter = re.compile(trigger['url-filter'])
                    self.assertEqual(rule['action'], {'type': 'block'})
                    self.assertIn('script', trigger['resource-type'])
                    authority = host + ('.' if dotted else '')
                    self.assertIsNotNone(url_filter.search(f'https://{authority}:8443/beacon'))
                    self.assertIsNotNone(url_filter.search(f'https://fixture@{authority}/beacon'))
                    self.assertIsNone(url_filter.search(f'https://unlisted.{host}/beacon'))
                    self.assertIsNone(url_filter.search(f'https://{host}.other.example/beacon'))
                    self.assertIsNone(url_filter.search(f'https://other.example/{host}/beacon'))
                    self.assertIsNone(url_filter.search(f'https://{host}@other.example/beacon'))
        self.assertEqual(found, {(host, dotted) for host in samples for dotted in (True, False)})
        parent_rules, counts = c.cname_rules('track.example\nchild.track.example\n')
        self.assertEqual(counts, {'hosts': 2, 'parent_hosts': 1, 'covered_by_parent': 1})
        self.assertEqual(len(parent_rules), 2)
        self.assertTrue(any(re.search(rule['trigger']['url-filter'], 'https://child.track.example/') for rule in parent_rules))

if __name__=='__main__': unittest.main(verbosity=2)
