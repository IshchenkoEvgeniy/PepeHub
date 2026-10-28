"""Fetch unmodified, offline reader fonts and licenses from google/fonts.

Sources are pinned to one repository revision and recorded with SHA-256.
Run from the repository root. Existing application fonts are kept unchanged.
"""
import hashlib
import json
import re
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from urllib.parse import quote

ROOT = Path(__file__).resolve().parent.parent
DEST = ROOT / 'apps/pepehub/assets/fonts'
FAMILIES = ['Literata', 'Merriweather', 'NotoSerif', 'PTSerif', 'PTSans', 'Roboto', 'OpenSans']
REVISION = '9b59ea9f333c5b8a99fa44e2a698496d6cde5b8e'


def fetch(url):
    request = urllib.request.Request(url, headers={'User-Agent': 'PepeHub-font-bundler'})
    with urllib.request.urlopen(request, timeout=90) as response:
        return response.read()


def main():
    revision = REVISION
    base = f'https://raw.githubusercontent.com/google/fonts/{revision}/ofl'

    def family(name):
        directory = name.lower()
        metadata = fetch(f'{base}/{directory}/METADATA.pb').decode('utf-8')
        if 'subsets: "cyrillic"' not in metadata or 'license: "OFL"' not in metadata:
            raise ValueError(f'{name}: Cyrillic/OFL metadata missing')
        files = []
        for block in re.findall(r'fonts \{(.*?)\n\}', metadata, re.S):
            weight = int(re.search(r'weight: (\d+)', block)[1])
            if weight not in (400, 700):
                continue
            style = re.search(r'style: "([^"]+)"', block)[1]
            filename = re.search(r'filename: "([^"]+)"', block)[1]
            suffix = ('-BoldItalic' if style == 'italic' else '-Bold') if weight == 700 else ('-Italic' if style == 'italic' else '')
            target = f'{name}{suffix}.ttf'
            url = f'{base}/{directory}/{quote(filename)}'
            content = fetch(url)
            if content[:4] not in (b'\x00\x01\x00\x00', b'OTTO'):
                raise ValueError(f'{target}: not an SFNT font')
            (DEST / target).write_bytes(content)
            files.append(dict(file=target, family='Reader' + name, weight=weight,
                              style=style, url=url, sha256=hashlib.sha256(content).hexdigest()))
        for original, target in [('OFL.txt', name + '-OFL.txt'), ('FONTLOG.txt', name + '-FONTLOG.txt')]:
            if original == 'FONTLOG.txt' and name != 'Merriweather':
                continue
            content = fetch(f'{base}/{directory}/{original}')
            (DEST / target).write_bytes(content)
        return files

    with ThreadPoolExecutor(max_workers=4) as pool:
        files = [entry for group in pool.map(family, FAMILIES) for entry in group]
    (DEST / 'reader-fonts.json').write_text(json.dumps(dict(repository='google/fonts', revision=revision, files=files), ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    for entry in files:
        print(f"{entry['file']}: {entry['weight']} {entry['style']}, {(DEST / entry['file']).stat().st_size} bytes")
    print(f'Pinned google/fonts revision: {revision}')


if __name__ == '__main__':
    main()
