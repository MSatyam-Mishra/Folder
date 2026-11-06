#!/usr/bin/env bash
# Packages the Linux build (flutter build linux --release) as .tar.gz, .tar.xz,
# .deb, .rpm and .AppImage. Used by .github/workflows/desktop-release.yml:
#   packaging/linux/make-packages.sh <version> <bundle> <portable bundle> <out>
# The portable bundle also carries libmpv and Tesseract and the libraries
# they need (for the archives and the AppImage); the .deb and .rpm depend on
# the system's libmpv and recommend its Tesseract.
# Needs fpm (gem install fpm), rpm (for rpmbuild) and internet access (it
# downloads appimagetool).
set -euo pipefail

version=$1
bundle=$(realpath "$2")
portable=$(realpath "$3")
out=$(realpath -m "$4")
here=$(cd "$(dirname "$0")" && pwd)
id=com.synqixlabs.folders
name=folders-v$version-linux
work=$(mktemp -d)
mkdir -p "$out"

# Archives: an folders/ folder holding the app.
mkdir -p "$work/tar/folders"
cp -a "$portable/." "$work/tar/folders/"
tar -C "$work/tar" -czf "$out/$name-x64.tar.gz" folders
tar -C "$work/tar" -cJf "$out/$name-x64.tar.xz" folders

# The installed layout, shared by the .deb, the .rpm and the AppImage.
root=$work/root
mkdir -p "$root/usr/lib/folders" "$root/usr/bin"
cp -a "$bundle/." "$root/usr/lib/folders/"
ln -s ../lib/folders/folders "$root/usr/bin/folders"
install -Dm644 "$here/$id.desktop" "$root/usr/share/applications/$id.desktop"
install -Dm644 "$here/$id.metainfo.xml" "$root/usr/share/metainfo/$id.metainfo.xml"
cp -a "$here/icons" "$root/usr/share/"

common=(
  -s dir -C "$root" -n folders -v "$version" --iteration 1
  --license GPL-3.0-or-later --vendor MSatyam-Mishra
  --maintainer 'MSatyam-Mishra <https://github.com/MSatyam-Mishra>'
  --url https://github.com/MSatyam-Mishra/explorer
  --description 'Universal file manager: open, edit and share almost any file'
)
# GTK 3, and EGL, GLES and GL, which Flutter loads through libepoxy;
# glibc 2.38 and libstdc++ 13.2 (GLIBCXX_3.4.32) for rive_native's prebuilt
# library. The .rpm names libraries, not packages, so it suits Fedora,
# openSUSE and others alike.
fpm "${common[@]}" -t deb -a amd64 --category utils \
  -d 'libgtk-3-0t64 | libgtk-3-0' -d libegl1 -d libgles2 -d libgl1 -d 'libmpv2 | libmpv1' \
  -d 'libc6 (>= 2.38)' -d 'libstdc++6 (>= 13.2)' \
  --deb-recommends tesseract-ocr --deb-recommends tesseract-ocr-eng \
  -p "$out/$name-amd64.deb" usr
fpm "${common[@]}" -t rpm -a x86_64 --rpm-os linux \
  -d 'libgtk-3.so.0()(64bit)' -d 'libEGL.so.1()(64bit)' -d 'libGLESv2.so.2()(64bit)' -d 'libGL.so.1()(64bit)' \
  -d 'libmpv.so.2()(64bit)' \
  -d 'libc.so.6(GLIBC_2.38)(64bit)' -d 'libstdc++.so.6(GLIBCXX_3.4.32)(64bit)' \
  --rpm-tag 'Recommends: tesseract' --rpm-tag 'Recommends: tesseract-langpack-eng' \
  --rpm-tag 'Recommends: tesseract-ocr' --rpm-tag 'Recommends: tesseract-ocr-traineddata-english' \
  -p "$out/$name-x86_64.rpm" usr

# AppImage
appdir=$work/Folders.AppDir
mkdir -p "$appdir"
cp -a "$root/usr" "$appdir/"
cp -a "$portable/lib/." "$appdir/usr/lib/folders/lib/"
cp -a "$portable/tesseract" "$appdir/usr/lib/folders/"
# appimagetool fails on AppStream data its validator dislikes; it's optional.
rm -rf "$appdir/usr/share/metainfo"
cp "$here/$id.desktop" "$appdir/"
cp "$here/icons/hicolor/256x256/apps/$id.png" "$appdir/$id.png"
cat > "$appdir/AppRun" <<'EOF'
#!/bin/sh
here=$(dirname "$(readlink -f "$0")")
exec "$here/usr/lib/folders/folders" "$@"
EOF
chmod +x "$appdir/AppRun"
curl -fsSL -o "$work/appimagetool" \
  https://github.com/AppImage/appimagetool/releases/download/continuous/appimagetool-x86_64.AppImage
chmod +x "$work/appimagetool"
ARCH=x86_64 APPIMAGE_EXTRACT_AND_RUN=1 "$work/appimagetool" "$appdir" "$out/$name-x86_64.AppImage"

rm -rf "$work"
ls -l "$out"
