import 'package:explorer/core/services/video_downloader/license_texts.dart';
import 'package:flutter/foundation.dart';

/// Where the source code of this app is published (GPL-3.0 §6).
const appSourceUrl = 'https://github.com/MSatyam-Mishra/explorer';

/// The notice shown on the licences page.
const appLegalese =
    'Explorer is free software: you can redistribute it and/or modify it '
    'under the terms of the GNU General Public License, version 3 or (at '
    'your option) any later version. It comes with ABSOLUTELY NO WARRANTY.\n\n'
    'Source code: $appSourceUrl';

bool _registered = false;

/// Adds the app's own licence and those of native libraries that aren't Dart
/// packages (PDFium) to Flutter's [LicenseRegistry]. Call once at startup.
void registerAppLicenses() {
  if (_registered) return;
  _registered = true;
  LicenseRegistry.addLicense(_entries);
}

Stream<LicenseEntry> _entries() async* {
  yield const LicenseEntryWithLineBreaks(['Explorer'], appLegalese);
  yield const LicenseEntryWithLineBreaks(['Explorer'], gpl3Text);
  yield const LicenseEntryWithLineBreaks(['PDFium'], _pdfium);
  yield const LicenseEntryWithLineBreaks(['python-pptx (blank presentation)'], _pythonPptx);
  yield const LicenseEntryWithLineBreaks(['Sweet folders (Sweet style)'], _sweetFolders);
  yield const LicenseEntryWithLineBreaks(['Dracula Icons (Dracula style)'], _draculaIcons);
  yield const LicenseEntryWithLineBreaks(['Sweet folders (Sweet style)', 'Dracula Icons (Dracula style)'], gpl3Text);
}

const _pythonPptx = '''
The blank .pptx that New file creates comes from python-pptx's default template.

The MIT License (MIT)
Copyright (c) 2013 Steve Canny, https://github.com/scanny

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.
''';

const _sweetFolders = '''
Sweet folders, Sweet-Rainbow (folder and place icons of the Sweet style)
by Eliver Lara. Source: https://github.com/EliverLara/Sweet-folders
Licensed under the GNU General Public License, version 3.''';

const _draculaIcons = '''
Dracula Icons (folder and place icons of the Dracula style) by Matheus
Vitor, recoloured from Papirus (https://github.com/PapirusDevelopmentTeam/papirus-icon-theme)
to the Dracula palette. Source: https://github.com/m4thewz/dracula-icons
Licensed under the GNU General Public License, version 3.''';

const _pdfium = '''
PDFium (PDF rendering and editing, via pdfrx)
Source: https://pdfium.googlesource.com/pdfium/

Copyright 2014 The PDFium Authors

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are
met:

   * Redistributions of source code must retain the above copyright
notice, this list of conditions and the following disclaimer.
   * Redistributions in binary form must reproduce the above
copyright notice, this list of conditions and the following disclaimer
in the documentation and/or other materials provided with the
distribution.
   * Neither the name of Google Inc. nor the names of its
contributors may be used to endorse or promote products derived from
this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
"AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

PDFium includes third-party code under their own permissive licences
(FreeType, libjpeg-turbo, Little CMS, OpenJPEG, libpng, zlib); see the
LICENSE files in the PDFium source tree.
''';
