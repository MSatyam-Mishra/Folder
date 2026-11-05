"""Builds release APKs for every ABI plus a universal APK.

Run from the project root:
    python tool/build_release.py [--without-video-downloader]

--without-video-downloader leaves out the video downloader (GPL-3.0
youtubedl-android, ~4 MB per APK; its Python and FFmpeg engine is never in
the APK but downloaded on first use) and its menu entry and share target.

Output: build/release/v<version>/folder-v<version>-<abi>.apk, the universal
APK and SHA256SUMS.txt. Dart code is obfuscated; the symbols needed to decode
crash stack traces (`flutter symbolize`) are kept in build/symbols/v<version>/
— keep them for every published release.

Signing uses android/key.properties (git-ignored). Without it the APKs are
signed with the debug key, which can't update an installed release.
"""
import hashlib
import os
import re
import shutil
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ABIS = ['arm64-v8a', 'armeabi-v7a', 'x86_64']


def main():
    without_downloader = '--without-video-downloader' in sys.argv[1:]
    with open(os.path.join(ROOT, 'pubspec.yaml'), encoding='utf-8') as f:
        version = re.search(r'^version:\s*([0-9.]+)', f.read(), re.M).group(1)
    if not os.path.exists(os.path.join(ROOT, 'android', 'key.properties')):
        print('WARNING: android/key.properties missing; APKs will be debug-signed.')

    flutter = shutil.which('flutter') or shutil.which('flutter.bat')
    symbols = os.path.join(ROOT, 'build', 'symbols', f'v{version}')
    common = ['build', 'apk', '--release', '--obfuscate', f'--split-debug-info={symbols}',
              '--android-skip-build-dependency-validation']
    if without_downloader:
        common += ['--dart-define=VIDEO_DOWNLOADER=false',
                   '--android-project-arg=explorer.videoDownloader=false']
        print('Building without the video downloader.')
    for extra in (['--split-per-abi'], []):
        print('flutter', ' '.join(common + extra))
        subprocess.run([flutter, *common, *extra], cwd=ROOT, check=True)
        if extra:
            # The universal build reuses the output folder; take the splits first.
            stage(version, split=True)
    stage(version, split=False)


def stage(version, split):
    built = os.path.join(ROOT, 'build', 'app', 'outputs', 'flutter-apk')
    out = os.path.join(ROOT, 'build', 'release', f'v{version}')
    os.makedirs(out, exist_ok=True)
    names = ([(f'app-{abi}-release.apk', abi) for abi in ABIS] if split
             else [('app-release.apk', 'universal')])
    for src, label in names:
        shutil.copyfile(os.path.join(built, src),
                        os.path.join(out, f'folder-v{version}-{label}.apk'))
    if split:
        return
    lines = []
    for name in sorted(os.listdir(out)):
        if name.endswith('.apk'):
            with open(os.path.join(out, name), 'rb') as f:
                digest = hashlib.sha256(f.read()).hexdigest()
            size = os.path.getsize(os.path.join(out, name)) / 1e6
            lines.append(f'{digest}  {name}\n')
            print(f'{size:6.1f} MB  {name}')
    with open(os.path.join(out, 'SHA256SUMS.txt'), 'w', encoding='utf-8', newline='\n') as f:
        f.writelines(lines)
    print('release files in', out)


if __name__ == '__main__':
    sys.exit(main())
