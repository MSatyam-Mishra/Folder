import 'dart:io';
import 'dart:typed_data';

import 'package:explorer/core/platform/explorer_paths.dart';
import 'package:explorer/core/services/thumbnails/system_icons.dart';
import 'package:explorer/core/theme/app_style.dart';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:path/path.dart' as p;
import 'package:shadcn_ui/shadcn_ui.dart' show LucideIcons;

/// Folders the system names: the home folder and the libraries in it.
/// Styles with an icon theme (Sweet, Dracula) have an icon for each; the
/// others mark them with a symbol, as Finder and File Explorer do.
enum Place {
  home, desktop, documents, downloads, music, pictures, videos, templates, public;

  /// The place a folder named [name] is, if any ([path] tells the home
  /// folder).
  static Place? of(String path, {String? name}) {
    final home = Platform.environment[Platform.isWindows ? 'USERPROFILE' : 'HOME'];
    if (home != null && home.isNotEmpty && p.equals(path, home)) return Place.home;
    return named(name ?? p.basename(path));
  }

  /// By name alone: sidebar entries ("Downloads", "Photos", "User folder").
  static Place? named(String name) => switch (name.toLowerCase()) {
        'user folder' || 'home' => Place.home,
        'desktop' => Place.desktop,
        'documents' || 'my documents' => Place.documents,
        'downloads' || 'download' => Place.downloads,
        'music' || 'audio' => Place.music,
        'pictures' || 'photos' || 'images' => Place.pictures,
        'videos' || 'video' || 'movies' => Place.videos,
        'templates' => Place.templates,
        'public' => Place.public,
        _ => null,
      };

  /// The icon's name in the icon themes (assets/icon_themes/).
  String get _file => switch (this) {
        Place.home => 'folder-home',
        Place.desktop => 'user-desktop',
        Place.documents => 'folder-documents',
        Place.downloads => 'folder-download',
        Place.music => 'folder-music',
        Place.pictures => 'folder-pictures',
        Place.videos => 'folder-videos',
        Place.templates => 'folder-templates',
        Place.public => 'folder-publicshare',
      };

  /// The style's icon for this place, or null without an icon theme.
  String? assetFor(AppLook look) {
    final pack = look.iconPack;
    return pack == null ? null : 'assets/icon_themes/$pack/$_file.svg';
  }

  /// The place's folder, for its icon; null if it has no fixed one.
  String? get folder {
    final home = Platform.environment[Platform.isWindows ? 'USERPROFILE' : 'HOME'];
    if (home == null || home.isEmpty) return null;
    return switch (this) {
      Place.home => home,
      Place.desktop => p.join(home, 'Desktop'),
      Place.documents => p.join(home, 'Documents'),
      Place.downloads => p.join(home, 'Downloads'),
      Place.music => p.join(home, 'Music'),
      Place.pictures => p.join(home, 'Pictures'),
      Place.videos => p.join(home, 'Videos'),
      Place.templates || Place.public => null,
    };
  }

  /// Its symbol in Finder's sidebar.
  IconData get finderGlyph => this == Place.downloads ? LucideIcons.circleArrowDown : glyph;

  /// The symbol on its folder where the style draws folders itself.
  IconData get glyph => switch (this) {
        Place.home => LucideIcons.house,
        Place.desktop => LucideIcons.monitor,
        Place.documents => LucideIcons.fileText,
        Place.downloads => LucideIcons.arrowDown,
        Place.music => LucideIcons.music,
        Place.pictures => LucideIcons.image,
        Place.videos => LucideIcons.film,
        Place.templates => LucideIcons.layoutTemplate,
        Place.public => LucideIcons.users,
      };
}

/// A sidebar or tab icon: Sweet's or Dracula's folder for a [place], the
/// system's own for [path] or the [place] in the Windows style (Finder's
/// sidebar has blue symbols, as the macOS style), else [icon].
class PlaceIcon extends StatelessWidget {
  const PlaceIcon({super.key, required this.place, required this.icon, this.path, this.size = 17, this.color});

  final Place? place;
  final IconData icon;
  final String? path;
  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final look = context.look;
    final asset = place?.assetFor(look);
    if (asset != null) {
      // The folder art is wider than tall: drawn a little bigger than the
      // symbols, in the same room so the labels stay in line.
      return SizedBox.square(
        dimension: size,
        child: Transform.scale(scale: 1.25, child: SvgPicture.asset(asset, fit: BoxFit.contain)),
      );
    }
    final mac = look.style == AppStyle.macos;
    final symbol = Icon(mac ? place?.finderGlyph ?? icon : icon, size: size, color: color);
    // A category has its place's icon: it's no folder on disk.
    final path = this.path;
    final folder = path != null && !ExplorerPaths.isCategory(path) ? path : place?.folder;
    if (look.systemIcons && !mac && folder != null) {
      return SystemIcon(path: folder, size: size, fallback: symbol);
    }
    return symbol;
  }
}

/// The icon the system itself shows for [path] ([SystemIcons]), or
/// [fallback] until it comes, or if there's none.
class SystemIcon extends StatefulWidget {
  const SystemIcon({super.key, required this.path, required this.size, required this.fallback});

  final String path;
  final double size;
  final Widget fallback;

  @override
  State<SystemIcon> createState() => _SystemIconState();
}

class _SystemIconState extends State<SystemIcon> {
  Uint8List? _bytes;
  String? _for;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _request();
  }

  @override
  void didUpdateWidget(SystemIcon oldWidget) {
    super.didUpdateWidget(oldWidget);
    _request();
  }

  void _request() {
    final pixels = (widget.size * MediaQuery.devicePixelRatioOf(context)).ceil();
    final key = '${widget.path}|$pixels';
    if (key == _for) return;
    _for = key;
    _bytes = SystemIcons.known(widget.path, pixels);
    SystemIcons.load(widget.path, pixels).then((bytes) {
      if (mounted && _for == key && bytes != null && !identical(bytes, _bytes)) {
        setState(() => _bytes = bytes);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final bytes = _bytes;
    return SizedBox.square(
      dimension: widget.size,
      child: bytes == null
          ? widget.fallback
          : Image.memory(
              bytes,
              fit: BoxFit.contain,
              gaplessPlayback: true,
              filterQuality: FilterQuality.medium,
              errorBuilder: (_, _, _) => widget.fallback,
            ),
    );
  }
}
