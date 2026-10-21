"""Stage archive inputs without changing reviewed sources or the finished-app guard.

Only App Store staging removes the exact nine keys compiled out of its Swift UI.
TestFlight resources remain byte-for-byte identical. No credentials are copied.
"""
import argparse
import json
from pathlib import Path
import shutil
from check_localizations import load_strings

LANGUAGES = ('zh-Hant', 'zh-Hans', 'en', 'ja', 'es', 'fr')
BETA_ONLY_KEYS = frozenset({
    'A new ChaiPhoto beta is available || ChaiPhoto 有新的測試版本',
    'Beta testing & feedback || Beta 測試與回報',
    'ChaiPhoto helps you quickly sort iPhone photos and videos with simple swipes. It is currently available as a free public beta. || ChaiPhoto 是一款用滑動快速整理 iPhone 照片與影片的 App，目前免費公開 Beta 測試中。',
    'Current %@ (%lld) · Latest %@ (%lld) || 目前 %@ (%lld) · 最新 %@ (%lld)',
    'Known issues & progress || 已知問題與處理進度',
    'Opening the report website does not automatically send app, device, or system information. If needed, copy the system information below and paste it yourself. || 開啟回報網站時不會自動傳送 App 版本、裝置或系統資訊。若需要，可先使用下方「複製系統資訊」，再由你自行貼到網站。',
    'Public TestFlight beta || TestFlight 公開測試',
    'Report a problem (recommended) || 回報問題（建議）',
    'TestFlight beta || TestFlight 測試中',
})


def stage(root, destination, flavor):
    root, destination = Path(root).resolve(), Path(destination).resolve()
    if flavor not in ('appstore', 'testflight'):
        raise ValueError('Unsupported archive resource flavor')
    if destination.exists() or destination.is_relative_to(root) or root.is_relative_to(destination):
        raise ValueError('Archive staging needs a new directory outside the reviewed checkout')
    source = root / 'ChaiPhoto'
    project = root / 'ChaiPhoto.xcodeproj'
    if not (project / 'project.pbxproj').is_file():
        raise ValueError('Generate and verify the reviewed Xcode project before staging')
    # Validate all inputs before creating a stage. The delivery script has already
    # checked the complete public allowlist, source manifest and generated project.
    originals = {}
    for code in LANGUAGES:
        path = source / 'Localization' / (code + '.lproj') / 'Localizable.strings'
        values = load_strings(path)
        if not BETA_ONLY_KEYS <= values.keys():
            raise ValueError('Missing expected Beta-only localization keys: ' + code)
        originals[code] = (path.read_bytes(), values)
    # Keep project-relative references intact; never stage the checkout's signing
    # script, credentials, repository history or unrelated private documentation.
    destination.mkdir(parents=True)
    shutil.copytree(source, destination / 'ChaiPhoto')
    shutil.copytree(project, destination / 'ChaiPhoto.xcodeproj')
    for code, (raw, values) in originals.items():
        path = destination / 'ChaiPhoto/Localization' / (code + '.lproj') / 'Localizable.strings'
        if flavor == 'appstore':
            kept = []
            for line in raw.splitlines(keepends=True):
                stripped = line.lstrip()
                if stripped.startswith(b'"'):
                    key, _ = json.JSONDecoder().raw_decode(stripped.decode('utf-8'))
                    if key in BETA_ONLY_KEYS:
                        continue
                kept.append(line)
            path.write_bytes(b''.join(kept))
        expected = {k: v for k, v in values.items() if flavor != 'appstore' or k not in BETA_ONLY_KEYS}
        if load_strings(path) != expected:
            raise ValueError('Unexpected staged localization change: ' + code)
        if flavor == 'testflight' and path.read_bytes() != raw:
            raise ValueError('TestFlight localization changed: ' + code)
    print(f'Archive resources staged: {flavor}; {len(LANGUAGES)} languages; '
          f'{len(BETA_ONLY_KEYS) if flavor == "appstore" else 0} Beta-only entries removed per language')


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--root', type=Path, default=Path.cwd())
    parser.add_argument('--destination', type=Path, required=True)
    parser.add_argument('--flavor', choices=['appstore', 'testflight'], required=True)
    args = parser.parse_args()
    stage(args.root, args.destination, args.flavor)
