import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Where a shortcut can go, each in its system's own way.
enum ShortcutPlace {
  /// Android: pinned by the launcher, which asks first.
  homeScreen,

  /// Android: the list shown on a long press of the app's icon.
  appIconMenu,

  /// Windows, Linux and macOS.
  desktop,

  /// Windows: a .lnk among the Start menu's programs.
  startMenu,

  /// Linux: a .desktop file, which menus and launchers list.
  appMenu,

  /// macOS: a small app in ~/Applications, for Launchpad and Spotlight.
  applications,
}

/// A way into one screen of the app from outside it.
class AppShortcut {
  const AppShortcut({
    required this.id,
    required this.title,
    required this.description,
    required this.icon,
    required this.route,
    this.desktopArgs,
  });

  final String id;
  final String title;
  final String description;
  final IconData icon;

  /// What the app opens, see `IncomingRoute`.
  final String route;

  /// On computers, in place of `--route=`.
  final List<String>? desktopArgs;

  List<String> get arguments => desktopArgs ?? ['${AppShortcuts.routeFlag}$route'];
}

/// Puts [AppShortcut]s where each system keeps them. Each opens the app at
/// that screen, under an icon drawn from the shortcut's own.
abstract final class AppShortcuts {
  static const routeFlag = '--route=';
  static const _channel = MethodChannel('explorer/device');

  /// The screen a command line asks for.
  static String? routeIn(List<String> args) {
    for (final arg in args) {
      if (arg.startsWith(routeFlag)) return arg.substring(routeFlag.length);
    }
    return null;
  }

  /// An MSIX: its AppData is private to it, so the Start menu's folder there
  /// wouldn't be the one Windows reads, and its folder changes with each update.
  static bool get _inMsix => Platform.resolvedExecutable.contains(r'\WindowsApps\');

  static List<ShortcutPlace> get places {
    if (Platform.isAndroid) return const [ShortcutPlace.homeScreen, ShortcutPlace.appIconMenu];
    if (Platform.isWindows) {
      return _inMsix ? const [ShortcutPlace.desktop] : const [ShortcutPlace.desktop, ShortcutPlace.startMenu];
    }
    if (Platform.isLinux) return const [ShortcutPlace.desktop, ShortcutPlace.appMenu];
    if (Platform.isMacOS) return const [ShortcutPlace.desktop, ShortcutPlace.applications];
    return const [];
  }

  /// Puts [shortcut] at [place]; false if the system refused. [colors] are
  /// the icon's gradient. [folder] is for tests, in place of the real one.
  static Future<bool> add(
    AppShortcut shortcut,
    ShortcutPlace place, {
    required List<Color> colors,
    @visibleForTesting Directory? folder,
  }) async {
    final png = await drawIcon(shortcut.icon, colors: colors, fullBleed: Platform.isAndroid);
    if (Platform.isAndroid) {
      final added = await _channel.invokeMethod<bool>('addShortcut', {
        'id': shortcut.id,
        'title': shortcut.title,
        'description': shortcut.description,
        'route': shortcut.route,
        'icon': png,
        'pin': place == ShortcutPlace.homeScreen,
      });
      return added ?? false;
    }
    if (Platform.isWindows) return _addWindows(shortcut, place, png, folder);
    if (Platform.isLinux) return _addLinux(shortcut, place, png, folder);
    if (Platform.isMacOS) return _addMac(shortcut, place, png, folder);
    return false;
  }

  /// The shortcut's icon as a PNG: white on a gradient. [fullBleed] fills the
  /// square with a smaller glyph, for launchers that cut their own shape.
  static Future<Uint8List> drawIcon(
    IconData icon, {
    required List<Color> colors,
    bool fullBleed = false,
    int size = 256,
  }) async {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    final extent = size.toDouble();
    final square = Offset.zero & Size.square(extent);
    final tile = fullBleed ? square : square.deflate(extent * 0.04);
    final paint = Paint()
      ..shader = ui.Gradient.linear(
        square.topLeft,
        square.bottomRight,
        [colors.first, colors.last],
      );
    if (fullBleed) {
      canvas.drawRect(tile, paint);
    } else {
      canvas.drawRRect(RRect.fromRectAndRadius(tile, Radius.circular(extent * 0.22)), paint);
    }
    final glyph = TextPainter(
      textDirection: TextDirection.ltr,
      text: TextSpan(
        text: String.fromCharCode(icon.codePoint),
        style: TextStyle(
          fontFamily: icon.fontFamily,
          package: icon.fontPackage,
          fontSize: extent * (fullBleed ? 0.42 : 0.56),
          color: Colors.white,
        ),
      ),
    )..layout();
    glyph.paint(canvas, square.center - Offset(glyph.width / 2, glyph.height / 2));
    glyph.dispose();
    final image = await recorder.endRecording().toImage(size, size);
    try {
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      return data!.buffer.asUint8List();
    } finally {
      image.dispose();
    }
  }

  /// Keeps the title's look, without what a file name can't hold.
  @visibleForTesting
  static String fileNameFor(String title) => title.replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1f]'), '').trim();

  static Future<File> _saveIcon(AppShortcut shortcut, String extension, List<int> bytes, Directory? folder) async {
    final base = folder ?? await getApplicationSupportDirectory();
    final file = File(p.join(base.path, 'shortcut_icons', '${shortcut.id}.$extension'));
    await file.parent.create(recursive: true);
    return file.writeAsBytes(bytes, flush: true);
  }

  // Windows

  static const _windowsScript = r'''
$ErrorActionPreference = 'Stop'
$folder = $env:EXPLORER_LNK_FOLDER
if (-not $folder) { $folder = [Environment]::GetFolderPath($env:EXPLORER_LNK_KNOWN) }
$shell = New-Object -ComObject WScript.Shell
$link = $shell.CreateShortcut((Join-Path $folder ($env:EXPLORER_LNK_NAME + '.lnk')))
$link.TargetPath = $env:EXPLORER_LNK_TARGET
$link.Arguments = $env:EXPLORER_LNK_ARGS
$link.Description = $env:EXPLORER_LNK_DESCRIPTION
if ($env:EXPLORER_LNK_ICON) { $link.IconLocation = $env:EXPLORER_LNK_ICON }
$link.WorkingDirectory = Split-Path $env:EXPLORER_LNK_TARGET
$link.Save()
''';

  /// An MSIX's own folder can't be started from outside, so its shortcuts go
  /// through the alias Windows keeps for it (see AppxManifest.xml).
  static String get _windowsTarget {
    if (!_inMsix) return Platform.resolvedExecutable;
    final local = Platform.environment['LOCALAPPDATA'] ?? '';
    return p.join(local, 'Microsoft', 'WindowsApps', p.basename(Platform.resolvedExecutable));
  }

  static Future<bool> _addWindows(AppShortcut shortcut, ShortcutPlace place, Uint8List png, Directory? folder) async {
    final tile = img.decodePng(png)!;
    final smaller = [
      for (final size in [64, 48, 32, 16]) img.copyResize(tile, width: size, interpolation: img.Interpolation.average),
    ];
    smaller.forEach(tile.addFrame);
    final ico = img.encodeIco(tile);
    // Inside an MSIX this folder is private to it, where the shell can't read
    // the icon: those keep the app's own.
    final icon = _inMsix ? '${Platform.resolvedExecutable},0' : (await _saveIcon(shortcut, 'ico', ico, folder)).path;
    final result = await Process.run(
      'powershell.exe',
      ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-Command', _windowsScript],
      // As variables, so that no name or path can change the script.
      environment: {
        if (folder != null) 'EXPLORER_LNK_FOLDER': folder.path,
        'EXPLORER_LNK_KNOWN': place == ShortcutPlace.startMenu ? 'Programs' : 'Desktop',
        'EXPLORER_LNK_NAME': fileNameFor(shortcut.title),
        'EXPLORER_LNK_TARGET': _windowsTarget,
        'EXPLORER_LNK_ARGS': shortcut.arguments.map((arg) => '"$arg"').join(' '),
        'EXPLORER_LNK_DESCRIPTION': shortcut.description,
        'EXPLORER_LNK_ICON': icon,
      },
    );
    return result.exitCode == 0;
  }

  // Linux

  /// How this copy of the app gets started: packages run through their own
  /// launcher, not the file inside them.
  static List<String> get _linuxCommand {
    final env = Platform.environment;
    final appImage = env['APPIMAGE'];
    if (appImage != null && appImage.isNotEmpty) return [appImage];
    final flatpak = env['FLATPAK_ID'];
    if (flatpak != null && flatpak.isNotEmpty) return ['flatpak', 'run', flatpak];
    if ((env['SNAP_NAME'] ?? '').isNotEmpty) return ['snap', 'run', env['SNAP_NAME']!];
    return [Platform.resolvedExecutable];
  }

  /// One word of a .desktop file's Exec line.
  static String _execWord(String word) {
    if (!RegExp(r'''[\s"'\\$`%]''').hasMatch(word)) return word;
    final escaped = word
        .replaceAll(r'\', r'\\')
        .replaceAll('"', r'\"')
        .replaceAll(r'$', r'\$')
        .replaceAll('`', r'\`')
        .replaceAll('%', '%%');
    return '"$escaped"';
  }

  @visibleForTesting
  static String desktopEntry(AppShortcut shortcut, List<String> command, String iconPath) => [
        '[Desktop Entry]',
        'Type=Application',
        'Version=1.0',
        'Name=${shortcut.title}',
        'Comment=${shortcut.description}',
        'Exec=${[...command, ...shortcut.arguments].map(_execWord).join(' ')}',
        'Icon=$iconPath',
        'Terminal=false',
        'Categories=Utility;',
        '',
      ].join('\n');

  static Future<Directory> _linuxDesktop() async {
    final home = Platform.environment['HOME'] ?? '';
    try {
      final named = await Process.run('xdg-user-dir', ['DESKTOP']);
      final path = (named.stdout as String).trim();
      if (named.exitCode == 0 && path.isNotEmpty && path != home) return Directory(path);
    } on ProcessException {
      // Not installed: the usual name, then.
    }
    return Directory(p.join(home, 'Desktop'));
  }

  static Future<bool> _addLinux(AppShortcut shortcut, ShortcutPlace place, Uint8List png, Directory? folder) async {
    final home = Platform.environment['HOME'] ?? '';
    final onDesktop = place == ShortcutPlace.desktop;
    final target = folder ??
        (onDesktop ? await _linuxDesktop() : Directory(p.join(home, '.local', 'share', 'applications')));
    await target.create(recursive: true);
    final icon = await _saveIcon(shortcut, 'png', png, folder);
    final file = File(p.join(target.path, 'com.synqixlabs.explory.${shortcut.id}.desktop'));
    await file.writeAsString(desktopEntry(shortcut, _linuxCommand, icon.path), flush: true);
    await Process.run('chmod', ['+x', file.path]);
    if (onDesktop) {
      // GNOME's desktop starts only files marked as trusted; elsewhere this
      // does nothing, or isn't there at all.
      try {
        await Process.run('gio', ['set', file.path, 'metadata::trusted', 'true']);
      } on ProcessException {
        // Then the desktop asks once, which is fine too.
      }
    }
    return true;
  }

  // macOS

  /// A file name or path, for the small script of a Mac shortcut.
  static String _shellWord(String word) => "'${word.replaceAll("'", r"'\''")}'";

  static String _xml(String text) =>
      text.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;');

  /// A shortcut on a Mac is a small app that asks for this one with its
  /// arguments: `open -n`, as a new window does.
  @visibleForTesting
  static String macScript(String explorerApp, List<String> arguments) => [
        '#!/bin/sh',
        "exec /usr/bin/open -n ${_shellWord(explorerApp)} --args ${arguments.map(_shellWord).join(' ')}",
        '',
      ].join('\n');

  @visibleForTesting
  static String macInfoPlist(AppShortcut shortcut) => '''
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>run</string>
  <key>CFBundleIconFile</key><string>icon</string>
  <key>CFBundleIdentifier</key><string>com.synqixlabs.explory.shortcut.${_xml(shortcut.id)}</string>
  <key>CFBundleName</key><string>${_xml(shortcut.title)}</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
''';

  static Future<bool> _addMac(AppShortcut shortcut, ShortcutPlace place, Uint8List png, Directory? folder) async {
    // <bundle>.app/Contents/MacOS/<name>
    final bundle = p.dirname(p.dirname(p.dirname(Platform.resolvedExecutable)));
    final home = Platform.environment['HOME'] ?? '';
    final target = folder ?? Directory(p.join(home, place == ShortcutPlace.applications ? 'Applications' : 'Desktop'));
    final contents = Directory(p.join(target.path, '${fileNameFor(shortcut.title)}.app', 'Contents'));
    final script = File(p.join(contents.path, 'MacOS', 'run'));
    await script.parent.create(recursive: true);
    await script.writeAsString(macScript(bundle, shortcut.arguments), flush: true);
    await File(p.join(contents.path, 'Info.plist')).writeAsString(macInfoPlist(shortcut), flush: true);
    final icon = await _saveIcon(shortcut, 'png', png, folder);
    final resources = Directory(p.join(contents.path, 'Resources'));
    await resources.create(recursive: true);
    // No icon is no reason to fail: it then shows a plain app's.
    await Process.run('/usr/bin/sips', ['-s', 'format', 'icns', icon.path, '--out', p.join(resources.path, 'icon.icns')]);
    final made = await Process.run('/bin/chmod', ['755', script.path]);
    return made.exitCode == 0;
  }
}
