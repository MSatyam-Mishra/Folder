#!/usr/bin/env python3
"""Builds assets/fonts/app_icons.ttf: Lucide's light weight, with the icons in
HI_ICONS redrawn from assets/Hi-icons.

Every icon in the app is a LucideIcons.x from a font, and lib/core/theme/
icon_strokes.dart loads this one in that font's place, so the code stays as it
is. Icons the pack has nothing for stay Lucide. Folder and file icons stay too,
on purpose.

    pip install fonttools picosvg
    python tool/icons/build_icon_font.py

Run it from the repo's root after changing HI_ICONS or adding to the pack; a
Lucide name not used yet can simply be added.
"""
import glob
import os
import re
import sys

from fontTools.pens.cu2quPen import Cu2QuPen
from fontTools.pens.transformPen import TransformPen
from fontTools.pens.ttGlyphPen import TTGlyphPen
from fontTools.svgLib.path import parse_path
from fontTools.ttLib import TTFont
from picosvg.svg import SVG

PACK = 'assets/Hi-icons'
OUTPUT = 'assets/fonts/app_icons.ttf'

# Lucide's name: the Hi-icons file.
HI_ICONS = {
    # Adding, closing, states
    'plus': 'Add',
    'squarePlus': 'Add Square',
    'minus': 'Minus',
    'x': 'Close',
    'check': 'Tick',
    'circleCheck': 'Tick Circle',
    'circleX': 'Close Circle',
    'circleStop': 'Stop Circle',
    'circleAlert': 'Danger Circle',
    'triangleAlert': 'Danger Triangle',
    'info': 'Information Circle',
    'circleHelp': 'FAQ Circle',
    'circle': 'Record',
    'square': 'Stop',
    # Actions
    'search': 'Search 1',
    'settings': 'Setting',
    'slidersHorizontal': 'Filter 5',
    'trash': 'Delete 2',
    'trash2': 'Delete 2',
    'pencil': 'Edit 1',
    'penLine': 'Edit 2',
    'squarePen': 'Edit Square',
    'penTool': 'Pen',
    'eye': 'Show',
    'eyeOff': 'Hide',
    'link': 'Link',
    'ellipsis': 'More Circle',
    'ellipsisVertical': 'More Circle',
    'refreshCw': 'Repeate 3',
    'refreshCcw': 'Repeate 1',
    'download': 'Document Download 1',
    'upload': 'Document Upload 2',
    'send': 'Send 2',
    'power': 'Off',
    'crop': 'Crop 1',
    'scan': 'Scan 8',
    'scanText': 'Scan 10',
    'droplet': 'Drop',
    'droplets': 'Drop',
    'zoomIn': 'Zoom In',
    'zoomOut': 'Zoom Out',
    # Locks
    'lock': 'Lock 2',
    'lockKeyhole': 'Lock 3',
    'lockOpen': 'Unlock 2',
    'lockKeyholeOpen': 'Unlock 3',
    'keyRound': 'Password 1',
    'shieldCheck': 'Shield Tick',
    'shieldOff': 'Shield Cross',
    # Places and things
    'house': 'Home 1',
    'image': 'Image',
    'images': 'Image',
    'camera': 'Camera 1',
    'video': 'Video 2',
    'videoOff': 'Video Slash',
    'film': 'Video 1',
    'clapperboard': 'Video 1',
    'music': 'Music',
    'play': 'Play',
    'pause': 'Pause',
    'skipBack': 'Previous',
    'skipForward': 'Next',
    'moon': 'Moon',
    'sun': 'Sun 1',
    'star': 'Star 1',
    'heart': 'Heart 1',
    'bookmark': 'Bookmark 1',
    'bookmarkMinus': 'Bookmark 2',
    'wifi': 'Wifi',
    'usb': 'Flash Disk 1',
    'monitor': 'Display 4',
    'users': 'Group 2',
    'hash': 'Hashtag',
    'chartColumn': 'Chart',
    'layoutGrid': 'Category',
    'grid2x2': 'Category',
    # Actions on files and folders (not the icons of files and folders)
    'folderPlus': 'Folder Add 1',
    'folderX': 'Folder Cross 1',
    'filePlus': 'Document Add 2',
    'filePlus2': 'Document Add 2',
    'fileUp': 'Document Upload 4',
    'fileInput': 'Document Download 3',
    'fileOutput': 'Document Upload 3',
    'fileX': 'Document Fail 2',
    'fileX2': 'Document Fail 2',
}


def lucide_package():
    cache = os.environ.get('PUB_CACHE') or os.path.join(os.environ.get('LOCALAPPDATA', os.path.expanduser('~/.pub-cache')), 'Pub', 'Cache')
    found = sorted(glob.glob(os.path.join(cache, 'hosted', 'pub.dev', 'lucide_icons_flutter-*')))
    if not found:
        sys.exit('lucide_icons_flutter not found; run flutter pub get, or set PUB_CACHE')
    return found[-1]


def main():
    package = lucide_package()
    with open(os.path.join(package, 'lib', 'lucide_icons.dart'), encoding='utf-8') as f:
        codepoints = {
            name: int(code)
            for name, code in re.findall(r'static const IconData (\w+) = const IconData\(\s*(\d+)', f.read())
        }
    font = TTFont(os.path.join(package, 'assets', 'build_font', 'LucideVariable-w300.ttf'))
    cmap = font.getBestCmap()
    glyphs = font.getGlyphSet()
    glyf = font['glyf']
    size = font['head'].unitsPerEm

    # The icons fill the em: 24 SVG units across, y upward from 0.
    scale = size / 24
    plus = glyf[cmap[codepoints['plus']]]
    if abs((plus.xMin + plus.xMax) / 2 - size / 2) > 2 or abs((plus.yMin + plus.yMax) / 2 - size / 2) > 2:
        sys.exit('Lucide icons are not centred on the em any more; check the transform')

    for name, icon in HI_ICONS.items():
        code = codepoints[name]
        shapes = SVG.parse(os.path.join(PACK, icon + '.svg')).topicosvg().shapes()
        pen = TTGlyphPen(glyphs)
        curves = Cu2QuPen(pen, max_err=0.6)
        flipped = TransformPen(curves, (scale, 0, 0, -scale, 0, size))
        for shape in shapes:
            parse_path(shape.as_path().d, flipped)
        glyf[cmap[code]] = pen.glyph()

    # Lucide's hinting doesn't apply to the new outlines, and icons don't need it.
    font.save(OUTPUT)
    print(f'{OUTPUT}: {len(HI_ICONS)} icons from {PACK}, {os.path.getsize(OUTPUT) // 1024} KB')


if __name__ == '__main__':
    main()
