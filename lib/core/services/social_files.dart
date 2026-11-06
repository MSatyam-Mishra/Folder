import 'dart:io';
import 'dart:isolate';

import 'package:bootstrap_icons/bootstrap_icons.dart';
import 'package:folder/core/platform/explorer_paths.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show IconData;
import 'package:path/path.dart' as p;

/// An app whose saved files have their own place in the sidebar.
enum SocialApp {
  telegram('telegram', 'Telegram', BootstrapIcons.telegram),
  whatsapp('whatsapp', 'WhatsApp', BootstrapIcons.whatsapp),
  instagram('instagram', 'Instagram', BootstrapIcons.instagram),
  twitter('twitter', 'Twitter', BootstrapIcons.twitter_x);

  const SocialApp(this.id, this.label, this.icon);

  final String id;
  final String label;
  final IconData icon;

  static SocialApp? byId(String id) => values.where((app) => app.id == id).firstOrNull;
}

/// Where an app keeps files: a folder whose subfolders are tabs, or (with
/// [tab]) a folder that is one tab itself. With [only], just the subfolders
/// whose tab is in it show, and files lying loose there don't.
class _Place {
  const _Place(this.path, {this.tab, this.only});

  final String path;
  final String? tab;
  final Set<String>? only;
}

/// The files apps have saved, from the folders they're known to use: "All
/// files", and a tab for each kind (Images, Video, Documents...).
abstract final class SocialFiles {
  /// Where to look instead of the phone's storage; tests set it.
  @visibleForTesting
  static String? storageOverride;

  static const allFiles = 'All files';

  /// The kinds of WhatsApp files shown: voice notes, audio, statuses,
  /// stickers, backups and the app's other folders stay out.
  @visibleForTesting
  static const whatsAppTabs = {'Animated Gifs', 'Documents', 'Images', 'Video'};

  static List<_Place> _phonePlaces(SocialApp app, String s) => switch (app) {
        SocialApp.telegram => [
            _Place('$s/Telegram'),
            _Place('$s/Android/media/org.telegram.messenger/Telegram'),
            _Place('$s/Android/media/org.telegram.messenger.web/Telegram'),
            _Place('$s/Pictures/Telegram', tab: 'Images'),
            _Place('$s/Movies/Telegram', tab: 'Video'),
            _Place('$s/Music/Telegram', tab: 'Audio'),
            _Place('$s/Download/Telegram', tab: 'Downloads'),
          ],
        SocialApp.whatsapp => [
            _Place('$s/Android/media/com.whatsapp/WhatsApp/Media', only: whatsAppTabs),
            _Place('$s/WhatsApp/Media', only: whatsAppTabs),
            _Place('$s/Android/media/com.whatsapp.w4b/WhatsApp Business/Media', only: whatsAppTabs),
            _Place('$s/WhatsApp Business/Media', only: whatsAppTabs),
          ],
        SocialApp.instagram => [
            _Place('$s/Pictures/Instagram', tab: 'Images'),
            _Place('$s/Movies/Instagram', tab: 'Video'),
            _Place('$s/DCIM/Instagram', tab: 'Camera'),
            _Place('$s/Download/Instagram', tab: 'Downloads'),
            _Place('$s/Android/media/com.instagram.android'),
          ],
        SocialApp.twitter => [
            _Place('$s/Pictures/Twitter', tab: 'Images'),
            _Place('$s/Pictures/X', tab: 'Images'),
            _Place('$s/Movies/Twitter', tab: 'Video'),
            _Place('$s/Movies/X', tab: 'Video'),
            _Place('$s/DCIM/Twitter', tab: 'Camera'),
            _Place('$s/Download/Twitter', tab: 'Downloads'),
            _Place('$s/Download/X', tab: 'Downloads'),
            _Place('$s/Android/media/com.twitter.android'),
          ],
      };

  static List<_Place> _computerPlaces(SocialApp app, String h) => switch (app) {
        SocialApp.telegram => [
            _Place(p.join(h, 'Downloads', 'Telegram Desktop'), tab: 'Downloads'),
            _Place(p.join(h, 'Documents', 'Telegram Desktop'), tab: 'Documents'),
          ],
        SocialApp.whatsapp => [
            _Place(p.join(h, 'Downloads', 'WhatsApp'), tab: 'Downloads'),
            _Place(p.join(h, 'Pictures', 'WhatsApp'), tab: 'Images'),
            if (Platform.isWindows)
              _Place(
                p.join(h, 'AppData', 'Local', 'Packages', '5319275A.WhatsAppDesktop_cv1g1gvanyjgm', 'LocalState', 'shared',
                    'transfers'),
                tab: 'Received',
              ),
          ],
        SocialApp.instagram => [
            _Place(p.join(h, 'Pictures', 'Instagram'), tab: 'Images'),
            _Place(p.join(h, 'Downloads', 'Instagram'), tab: 'Downloads'),
          ],
        SocialApp.twitter => [
            _Place(p.join(h, 'Pictures', 'Twitter'), tab: 'Images'),
            _Place(p.join(h, 'Downloads', 'Twitter'), tab: 'Downloads'),
          ],
      };

  static List<_Place> _places(SocialApp app) {
    final storage = storageOverride;
    if (storage != null) return _phonePlaces(app, storage);
    if (Platform.isAndroid) return _phonePlaces(app, ExplorerPaths.androidInternalStorage);
    return _computerPlaces(app, ExplorerPaths.userFolder);
  }

  /// A subfolder's tab: "WhatsApp Images" is Images, ".Statuses" is Statuses;
  /// null for the other hidden ones, which are the app's own.
  @visibleForTesting
  static String? tabName(String folder) {
    if (folder == '.Statuses') return 'Statuses';
    if (folder.startsWith('.')) return null;
    final short = folder.replaceFirst(RegExp(r'^(WhatsApp Business|WhatsApp|Telegram|Instagram|Twitter) '), '');
    return short.isEmpty ? folder : short;
  }

  /// Each tab and the folders it shows, and the files lying loose in the app's
  /// own folders (only in All files). Works in any isolate.
  static (Map<String, List<String>>, List<String>) _scan(List<_Place> places) {
    final tabs = <String, List<String>>{};
    final loose = <String>[];
    for (final place in places) {
      final dir = Directory(place.path);
      if (!dir.existsSync()) continue;
      if (place.tab != null) {
        (tabs[place.tab!] ??= []).add(place.path);
        continue;
      }
      final only = place.only;
      try {
        for (final entry in dir.listSync(followLinks: false)) {
          final name = p.basename(entry.path);
          if (entry is Directory) {
            final tab = tabName(name);
            if (tab != null && (only == null || only.contains(tab))) (tabs[tab] ??= []).add(entry.path);
          } else if (entry is File && !name.startsWith('.') && only == null) {
            loose.add(entry.path);
          }
        }
      } on FileSystemException {
        // Not readable: nothing to show from it.
      }
    }
    return (tabs, loose);
  }

  /// [app]'s tabs, in order, after "All files".
  static Future<List<String>> tabs(SocialApp app) async {
    final places = _places(app);
    final (found, _) = await Isolate.run(() => _scan(places));
    return found.keys.toList()..sort();
  }

  /// The files of a social path: its tab's, or all of the app's.
  static Future<List<FileSystemEntity>> list(String path) async {
    final app = SocialApp.byId(ExplorerPaths.socialAppOf(path) ?? '');
    if (app == null) return const [];
    final places = _places(app);
    final tab = ExplorerPaths.socialTabOf(path);
    final files = await Isolate.run(() {
      final (found, loose) = _scan(places);
      final folders = tab == null ? [for (final dirs in found.values) ...dirs] : found[tab] ?? const <String>[];
      final seen = <String>{if (tab == null) ...loose};
      for (final folder in folders) {
        try {
          for (final entry in Directory(folder).listSync(recursive: true, followLinks: false)) {
            if (entry is File && !p.basename(entry.path).startsWith('.')) seen.add(entry.path);
          }
        } on FileSystemException {
          // As much as could be read.
        }
      }
      return seen.toList();
    });
    return [for (final file in files) File(file)];
  }
}
