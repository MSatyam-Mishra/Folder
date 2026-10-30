import 'dart:io';

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

/// A sidebar icon: the style's own for a [place] (Sweet's or Dracula's
/// folder), else [icon].
class PlaceIcon extends StatelessWidget {
  const PlaceIcon({super.key, required this.place, required this.icon, this.size = 18, this.color});

  final Place? place;
  final IconData icon;
  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final asset = place?.assetFor(context.look);
    if (asset == null) return Icon(icon, size: size, color: color);
    // The folder art is wider than tall: drawn a little bigger than the
    // symbols, in the same room so the labels stay in line.
    return SizedBox.square(
      dimension: size,
      child: Transform.scale(scale: 1.25, child: SvgPicture.asset(asset, fit: BoxFit.contain)),
    );
  }
}
