import 'package:flutter/foundation.dart';

import 'license_texts.dart';

bool _registered = false;

/// Adds the licenses of the video downloader's components to Flutter's
/// [LicenseRegistry] (shown by `showLicensePage`). Call once at startup.
///
/// Android bundles youtubedl-android 0.18.1 with yt-dlp and QuickJS, and
/// downloads its Python runtime and FFmpeg on first use. Desktop downloads
/// the official yt-dlp executable at run time (it is not part of the app)
/// and uses the system's FFmpeg.
void registerVideoDownloaderLicenses() {
  if (_registered) return;
  _registered = true;
  LicenseRegistry.addLicense(_entries);
}

Stream<LicenseEntry> _entries() async* {
  yield const LicenseEntryWithLineBreaks(['youtubedl-android'], _youtubedlAndroid);
  yield const LicenseEntryWithLineBreaks(['yt-dlp'], _ytDlp);
  yield const LicenseEntryWithLineBreaks(['yt-dlp'], unlicenseText);
  yield const LicenseEntryWithLineBreaks(['yt-dlp'], _meriyah);
  yield const LicenseEntryWithLineBreaks(['yt-dlp'], meriyahLicenseText);
  yield const LicenseEntryWithLineBreaks(['yt-dlp'], _astring);
  yield const LicenseEntryWithLineBreaks(['yt-dlp'], astringLicenseText);
  yield const LicenseEntryWithLineBreaks(['FFmpeg'], _ffmpeg);
  yield const LicenseEntryWithLineBreaks(['Python'], _python);
  yield const LicenseEntryWithLineBreaks(['Python'], pythonLicenseText);
  yield const LicenseEntryWithLineBreaks(['QuickJS'], _quickJs);
  yield const LicenseEntryWithLineBreaks(['QuickJS'], quickJsLicenseText);
  yield const LicenseEntryWithLineBreaks(
    ['youtubedl-android', 'FFmpeg', 'mutagen', 'GNU Readline', 'GNU dbm'],
    gpl3Text,
  );
  yield const LicenseEntryWithLineBreaks(
    [
      'OpenSSL',
      'Jackson',
      'Apache Commons IO',
      'Apache Commons Compress',
      'opencore-amr',
      'vo-amrwbenc',
    ],
    apache2Text,
  );
  yield const LicenseEntryWithLineBreaks(['Jackson'], _jackson);
  yield const LicenseEntryWithLineBreaks(
      ['Apache Commons IO', 'Apache Commons Compress'], _commons);
  yield const LicenseEntryWithLineBreaks(['OpenSSL'], _openssl);
  yield const LicenseEntryWithLineBreaks(['mutagen'], _mutagen);
}

const _youtubedlAndroid = '''
youtubedl-android 0.18.1 (Android only)
Maven: io.github.junkfood02.youtubedl-android:library, :ffmpeg and :common 0.18.1
Source: https://github.com/yausername/youtubedl-android

Copyright (C) 2019-2025 yausername and the youtubedl-android contributors.

Licensed under the GNU General Public License, version 3 (GPL-3.0). The full license text is listed under this package. It provides yt-dlp, a Python 3.12 runtime, FFmpeg 7.1.1 and QuickJS, each listed separately. Folder includes yt-dlp and QuickJS, and downloads the Python runtime and FFmpeg the first time you use the video downloader, unchanged from these packages, from https://github.com/MSatyam-Mishra/explorer/releases/tag/video-engine-0.18.1''';

const _ytDlp = '''
yt-dlp, a feature-rich command-line audio/video downloader
https://github.com/yt-dlp/yt-dlp

On Android the app ships yt-dlp 2025.11.12 (inside youtubedl-android) and can update it in-app to the latest stable release from GitHub. On Windows, macOS and Linux the official yt-dlp executable is downloaded from GitHub on first use; it is not distributed with the app.

yt-dlp is released into the public domain under the Unlicense. It includes yt-dlp-ejs (https://github.com/yt-dlp/ejs, Unlicense), which bundles meriyah 6.1.4 (ISC) and astring 1.9.0 (MIT).''';

const _meriyah = '''
meriyah 6.1.4 (bundled in yt-dlp-ejs)
https://github.com/meriyah/meriyah''';

const _astring = '''
astring 1.9.0 (bundled in yt-dlp-ejs)
https://github.com/davidbonnet/astring''';

const _ffmpeg = '''
FFmpeg 7.1.1 (Android only, from youtubedl-android's ffmpeg package, built by the Termux project)
https://ffmpeg.org — source: https://ffmpeg.org/releases/ and https://github.com/termux/termux-packages

This build of FFmpeg is licensed under the GNU General Public License, version 3 or later (GPL-3.0-or-later): it was configured with --enable-gpl and --enable-version3, and its libraries report "GPL version 3 or later". The GPL-3.0 text is listed under this package.

FFmpeg is a trademark of Fabrice Bellard, originator of the FFmpeg project.

The build also links, among others (license in brackets):
x264, x265, Xvid, vid.stab, Rubber Band, FFTW [GPL-2.0-or-later];
LAME [LGPL-2.0-or-later]; libbluray, FriBidi, libgme, GnuTLS, libsoxr, GLib, libv4l [LGPL-2.1-or-later]; mpg123, libssh [LGPL-2.1];
Nettle, GMP, libidn2, libunistring [LGPL-3.0-or-later or GPL-2.0-or-later];
SRT, ZeroMQ [MPL-2.0]; opencore-amr, vo-amrwbenc [Apache-2.0];
Opus, libvpx, libvorbis, libogg, Theora, libwebp, libopenmpt, PCRE2 [BSD-3-Clause];
dav1d, libaom, rav1e, libsamplerate [BSD-2-Clause]; SVT-AV1 [BSD-3-Clause-Clear]; VMAF [BSD-2-Clause-Patent];
FreeType [FTL or GPL-2.0-or-later]; HarfBuzz, Fontconfig, libxml2, Little CMS, Brotli [MIT and MIT-style];
libass, libsodium [ISC]; zimg [WTFPL]; zlib [Zlib]; bzip2 [bzip2-1.0.6]; XZ Utils [0BSD]; libpng [libpng-2.0].
Each library's source and license is available from the Termux package of the same name.''';

const _python = '''
Python 3.12.11 (Android only, from youtubedl-android, built by the Termux project)
https://www.python.org

Python is licensed under the Python Software Foundation License Version 2 (PSF-2.0); the full license, with its history, follows.

The runtime bundles: OpenSSL 3 [Apache-2.0]; libffi, Expat [MIT]; ncurses [X11/MIT]; GNU Readline, GNU dbm [GPL-3.0-or-later]; libxcrypt [LGPL-2.1-or-later]; zlib [Zlib]; bzip2 [bzip2-1.0.6]; XZ Utils [0BSD]; LLVM libc++ [Apache-2.0 WITH LLVM-exception]; the Mozilla CA certificate list [MPL-2.0]; and the Python packages mutagen [GPL-2.0-or-later] and pycryptodomex [BSD-2-Clause and public domain].''';

const _quickJs = '''
QuickJS 2025-04-26 (Android only, from youtubedl-android)
https://bellard.org/quickjs/

Used by yt-dlp to run JavaScript. MIT license.''';

const _jackson = '''
Jackson databind, core and annotations 2.11.1 (Android only, used by youtubedl-android)
https://github.com/FasterXML/jackson — Apache License 2.0.''';

const _commons = '''
Apache Commons IO 2.5 and Apache Commons Compress 1.12 (Android only, used by youtubedl-android)
Copyright The Apache Software Foundation. Apache License 2.0.
This product includes software developed at The Apache Software Foundation (https://www.apache.org/).''';

const _openssl = '''
OpenSSL 3 (Android only, part of the bundled Python runtime)
https://www.openssl.org — Apache License 2.0.''';

const _mutagen = '''
mutagen (Android only, part of the bundled Python runtime)
https://github.com/quodlibet/mutagen
Copyright (C) 2005-2024 the mutagen authors. GNU General Public License, version 2 or later (GPL-2.0-or-later); the GPL-3.0 text is listed under this package.''';
