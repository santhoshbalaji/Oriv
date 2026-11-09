#!/usr/bin/env python3
"""Static build-scope guard; not a substitute for a network privacy audit."""
from pathlib import Path
import plistlib
import re

root = Path(__file__).resolve().parents[1]
failures = []
for relative in ('Apps', 'Packages/BrowserKit/Sources'):
    for path in (root / relative).rglob('*.swift'):
        text = path.read_text()
        transport = path.relative_to(root).as_posix() == 'Packages/BrowserKit/Sources/BrowserEngine/ContinuityCloudTransport.swift'
        if re.search(r'^(?:@preconcurrency )?import (ProductivityKit|AssistantKit|EventKit)\b', text, re.M) or (not transport and re.search(r'^(?:@preconcurrency )?import CloudKit\b', text, re.M)):
            failures.append(f'{path.relative_to(root)} imports a retired service')
        if re.search(r'URLSession\.(shared|configuration)|URLSession\(configuration:|EKEventStore\(|SecItem(Add|CopyMatching|Update|Delete)\(', text) or (not transport and re.search(r'CKContainer\(', text)):
            failures.append(f'{path.relative_to(root)} adds an app-owned service client or credential access requiring review')
for relative in ('project.yml', 'Packages/BrowserKit/Package.swift'):
    text = (root / relative).read_text()
    for retired in ('ProductivityKit', 'AssistantKit', 'OrivShareExtension', 'CloudDevelopment', 'ORIV_CLOUD', 'ORIV_WORKSPACE'):
        if retired in text:
            failures.append(f'{relative} references retired target/configuration {retired}')
continuity_environments = {
    f'Apps/{platform}/{filename}': environment
    for platform in ('macOS', 'iOS')
    for filename, environment in (('Continuity.entitlements', 'Development'), ('ContinuityRelease.entitlements', 'Production'))
}
for path in (root / 'Apps').rglob('*.entitlements'):
    values = plistlib.loads(path.read_bytes())
    environment = continuity_environments.get(path.relative_to(root).as_posix())
    if environment:
        required = {'com.apple.developer.icloud-container-identifiers', 'com.apple.developer.icloud-container-environment', 'com.apple.developer.icloud-services'}
        if not required.issubset(values):
            failures.append(f'{path.relative_to(root)} is missing a required continuity capability')
        if environment == 'Production' and 'com.apple.developer.icloud-container-development-container-identifiers' in values:
            failures.append(f'{path.relative_to(root)} mixes development-only identifiers into production')
    for key in values:
        if environment and key in ('com.apple.developer.icloud-container-identifiers', 'com.apple.developer.icloud-container-development-container-identifiers', 'com.apple.developer.icloud-container-environment', 'com.apple.developer.icloud-services'):
            expected = environment if key.endswith('environment') else ['CloudKit'] if key.endswith('services') else ['iCloud.com.santhoshbalaji.oriv.browser.dev']
            if values[key] != expected: failures.append(f'{path.relative_to(root)} has an unexpected continuity capability')
            continue
        if 'icloud' in key or 'application-groups' in key or key in ('com.apple.security.network.server', 'com.apple.security.personal-information.calendars'):
            failures.append(f'{path.relative_to(root)} declares retired capability {key}')
for platform in ('macOS', 'iOS'):
    path = root / 'Apps' / platform / 'Resources/Info.plist'
    values = plistlib.loads(path.read_bytes())
    if any('Calendar' in key or 'Reminder' in key or 'Cloud' in key or 'Workspace' in key for key in values):
        failures.append(f'{path.relative_to(root)} declares retired service metadata')
    schemes = [scheme for item in values.get('CFBundleURLTypes', []) for scheme in item.get('CFBundleURLSchemes', [])]
    if set(schemes) != {'http', 'https'}:
        failures.append(f'{path.relative_to(root)} has unexpected URL registrations: {schemes}')
if failures:
    raise SystemExit('\n'.join(failures))
print('Browser scope: two shared packages; optional browser-only CloudKit transport; no AI/EventKit clients, extension target or retired entitlements.')
