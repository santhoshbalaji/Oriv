#!/usr/bin/env python3
import base64
import importlib.util
import json
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
        self.assertEqual(c.cosmetic_rules(parsed[2], parsed[3])[-1]["action"]["type"], "ignore-previous-rules")
    def test_domain_scope_and_badfilter(self):
        self.assertEqual(c.scope(['example.com']), {'if-domain':['*example.com']})
        with self.assertRaises(ValueError): c.scope(['example.com','~sub.example.com'])
        self.assertEqual(c.parse('||x.example^$script\n||x.example^$script,badfilter\n')[-1], {'input_lines':2,'dropped:badfilter':2})
    def test_balanced_cosmetics_are_simple_generic_selectors(self):
        entries=[({},'.ad'), ({'if-domain':['*example.com']}, '#banner'), ({}, 'div > .ad')]
        rules=c.cosmetic_rules(entries, [], True)
        self.assertEqual(len(rules),1); self.assertEqual(rules[0]['action']['selector'],'.ad')
    def test_bundle_headers_digests_and_counts(self):
        import hashlib
        manifest=json.loads((c.OUT/'manifest.json').read_text())
        for name, counts in manifest['counts'].items():
            self.assertEqual(sum(v for k,v in counts.items() if k != 'input_lines'),counts['input_lines'],name)
        for components in manifest['outputs'].values():
            for component in components:
                header,payload=(c.OUT/component['file']).read_bytes().split(b'\n',1)
                header=json.loads(header); self.assertEqual(header['license'],'CC-BY-SA-3.0')
                raw=zlib.decompress(base64.b64decode(payload), wbits=-15)
                self.assertEqual(len(raw),header['decodedBytes'])
                self.assertEqual(hashlib.sha256(raw).hexdigest(),component['sha256'])
                rules=json.loads(raw); self.assertEqual(len(rules),component['rules']); self.assertLess(len(rules),150000)
                seen_allow=False
                for rule in rules:
                    if rule['action']['type']=='ignore-previous-rules': seen_allow=True
                    else: self.assertFalse(seen_allow)

if __name__=='__main__': unittest.main(verbosity=2)
