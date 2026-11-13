"""Builds release APKs for every ABI plus a universal APK.

Run from the project root:
    python tool/build_release.py [--without-video-downloader]

--without-video-downloader leaves out the video downloader (GPL-3.0
youtubedl-android, ~4 MB per APK; its Python and FFmpeg engine is never in
the APK but downloaded on first use) and its menu entry and share target.

Output: build/release/v<version>/folders-v<version>-<abi>.apk, the universal
APK and SHA256SUMS.txt. Dart code is obfuscated; the symbols needed to decode
crash stack traces (`flutter symbolize`) are kept in build/symbols/v<version>/
— keep them for every published release.

Signing uses android/key.properties (git-ignored). Without it the APKs are
signed with the debug key, which can't update an installed release.

Google Drive, OneDrive and Dropbox need the app ids registered for Folders
(docs/cloud-setup.md), taken from the environment when set:
FOLDERS_GOOGLE_CLIENT_ID, FOLDERS_GOOGLE_CLIENT_SECRET,
FOLDERS_ONEDRIVE_CLIENT_ID and FOLDERS_DROPBOX_APP_KEY. A service whose ids
are missing isn't offered in that build. They go to flutter through a file,
never on the command line or in this script's output.
"""
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ABIS = ['arm64-v8a', 'armeabi-v7a', 'x86_64']
CLOUD_SERVICES = [
    ('Google Drive', ['FOLDERS_GOOGLE_CLIENT_ID', 'FOLDERS_GOOGLE_CLIENT_SECRET']),
    ('OneDrive', ['FOLDERS_ONEDRIVE_CLIENT_ID']),
    ('Dropbox', ['FOLDERS_DROPBOX_APP_KEY']),
]


def cloud_defines():
    """Writes the cloud services' ids from the environment to a file for
    --dart-define-from-file; returns its path, or None when there are none."""
    values = {key: os.environ[key] for _, keys in CLOUD_SERVICES for key in keys
              if os.environ.get(key)}
    on = [name for name, keys in CLOUD_SERVICES if all(k in values for k in keys)]
    print('Cloud services:', ', '.join(on) if on else 'none (no app ids in the environment)')
    if not values:
        return None
    path = os.path.join(ROOT, 'build', 'cloud_defines.json')
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, 'w', encoding='utf-8') as f:
        json.dump(values, f)
    return path


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
    defines = cloud_defines()
    if defines:
        common.append(f'--dart-define-from-file={defines}')
    try:
        for extra in (['--split-per-abi'], []):
            print('flutter', ' '.join(common + extra))
            subprocess.run([flutter, *common, *extra], cwd=ROOT, check=True)
            if extra:
                # The universal build reuses the output folder; take the splits first.
                stage(version, split=True)
    finally:
        if defines:
            os.remove(defines)
    stage(version, split=False)


def stage(version, split):
    built = os.path.join(ROOT, 'build', 'app', 'outputs', 'flutter-apk')
    out = os.path.join(ROOT, 'build', 'release', f'v{version}')
    os.makedirs(out, exist_ok=True)
    names = ([(f'app-{abi}-release.apk', abi) for abi in ABIS] if split
             else [('app-release.apk', 'universal')])
    for src, label in names:
        shutil.copyfile(os.path.join(built, src),
                        os.path.join(out, f'folders-v{version}-{label}.apk'))
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
