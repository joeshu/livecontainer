#!/usr/bin/env python3
"""Audit module-owned recovery translations and printf argument contracts."""
import argparse
from collections import Counter
import json
from pathlib import Path
import plistlib
import re

PAIR = re.compile(r'^\s*("(?:\\.|[^"\\])*")\s*=\s*("(?:\\.|[^"\\])*")\s*;\s*$', re.M)
FORMAT = re.compile(r'%(?:(\d+)\$)?[-+ #0]*(?:\d+|\*)?(?:\.(?:\d+|\*))?(hh|ll|[hljztL])?([@diuoxXfFeEgGcCsSp])')

def parse(path):
    pairs = [(json.loads(k), json.loads(v)) for k, v in PAIR.findall(path.read_text())]
    duplicates = [k for k, n in Counter(k for k, _ in pairs).items() if n > 1]
    assert not duplicates, f'{path}: duplicate keys: {duplicates}'
    assert pairs, f'{path}: no translations parsed'
    return dict(pairs)

def arguments(value):
    result = []
    index = 0
    for match in FORMAT.finditer(value.replace('%%', '')):
        index += 1
        position, length, kind = match.groups()
        result.append((int(position) if position else index, (length or '') + kind))
    return sorted(result)

def verify(root):
    catalogs = {lang: parse(root / 'AltStore' / f'{lang}.lproj' / 'CombinedLocalizable.strings')
                for lang in ['en', 'zh-Hans', 'zh-Hant']}
    english = catalogs['en']
    for language, catalog in catalogs.items():
        assert catalog.keys() == english.keys(), f'{language}: recovery key coverage differs'
        for key, value in catalog.items():
            assert value.strip(), f'{language}/{key}: empty translation'
            assert arguments(value) == arguments(english[key]), f'{language}/{key}: format mismatch'
    for src in (root / 'AltStore/zh-Hans.lproj').glob('*.strings'):
        target = root / 'AltStore/zh-Hant.lproj' / src.name
        assert target.is_file(), f'Missing traditional resource: {target}'
        hans, hant = parse(src), parse(target)
        assert hans.keys() == hant.keys(), f'{src.name}: traditional key coverage differs'
        for key, value in hans.items():
            assert arguments(value) == arguments(hant[key]), f'{src.name}/{key}: traditional format mismatch'
    info = plistlib.loads((root / 'AltStore/Info.plist').read_bytes())
    assert 'zh-Hant' in info['CFBundleLocalizations'], 'Traditional language missing in Info.plist'
    for source in ['AltStore/Authentication/ResignAltStoreViewController.swift', 'AltStore/Settings/SettingsViewController.swift']:
        text = (root / source).read_text()
        for key in re.findall(r'SideStoreLocalization\.(?:text|format)\("([^"]+)"', text):
            assert key in english, f'{source}: missing stable key {key}'
    host = Path(__file__).resolve().parents[2]
    refresh = {lang: parse(host / 'SideStoreSupport' / f'{lang}.lproj' / 'RefreshLocalizable.strings')
               for lang in ['en', 'zh-Hans', 'zh-Hant']}
    for lang, table in refresh.items():
        assert table.keys() == refresh['en'].keys(), f'{lang}: refresh error keys differ'
        for key, value in table.items():
            assert arguments(value) == arguments(refresh['en'][key]), f'{lang}/{key}: refresh format mismatch'
    source = (host / 'SideStoreSupport/SideStore.swift').read_text()
    for key in re.findall(r'RefreshLocalization.text\("([^"]+)"', source):
        assert key in refresh['en'], f'Missing refresh error key: {key}'
    print(f'PASS: {len(english)} stable recovery keys in 3 languages; traditional files and format arguments match')

if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('sidestore', type=Path)
    verify(parser.parse_args().sidestore)
