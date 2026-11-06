import 'dart:io';

import 'package:folders/core/files/file_types.dart';
import 'package:folders/shared/file_icons/file_icons.dart';
import 'package:filesize/filesize.dart';
import 'package:flutter/widgets.dart';
import 'package:intl/intl.dart';

/// `stat()` results for listed entities, attached to the entity objects so a
/// row scrolled back into view doesn't stat (and flicker) again. A fresh
/// directory listing creates new entity objects, so data never goes stale.
abstract final class EntityStats {
  static final _stats = Expando<FileStat>('stat');
  static final _pending = Expando<Future<FileStat?>>('pendingStat');

  static FileStat? peek(FileSystemEntity entity) => _stats[entity];

  static Future<FileStat?> load(FileSystemEntity entity) {
    return _pending[entity] ??= entity.stat().then<FileStat?>(
      (stat) {
        if (stat.type == FileSystemEntityType.notFound) return null;
        return _stats[entity] = stat;
      },
      onError: (Object _) => null,
    );
  }
}

/// Formatting shared by the explorer's rows and tiles.
abstract final class EntityFormat {
  static final _time = DateFormat.jm();
  static final _monthDay = DateFormat.MMMd();
  static final _full = DateFormat.yMMMd();

  /// "Today, 2:05 PM", "Yesterday", "Oct 3" or "Oct 3, 2024".
  static String date(DateTime date, {DateTime? now}) {
    now ??= DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final day = DateTime(date.year, date.month, date.day);
    final diff = today.difference(day).inDays;
    if (diff == 0) return 'Today, ${_time.format(date)}';
    if (diff == 1) return 'Yesterday, ${_time.format(date)}';
    if (date.year == now.year) return _monthDay.format(date);
    return _full.format(date);
  }

  static String size(int bytes) => filesize(bytes, 1);

  /// "Folder", "PDF document"…; on macOS "Application", "Installer
  /// package" or "Package" for packages, as in Finder.
  static String kind(FileSystemEntity entity) {
    if (_looksLikePackage(entity)) {
      return _packageKinds[FileTypes.extensionOf(entity.path)] ?? 'Package';
    }
    return entity is Directory
        ? 'Folder'
        : FileTypes.describe(FileTypes.kindOf(entity.path));
  }

  /// Whether [entity] is a macOS package (an app, installer or document
  /// package): a folder that shows, sorts and opens like a file, as in
  /// Finder. Goes by the name, so it costs no I/O.
  static bool isPackage(FileSystemEntity entity) =>
      Platform.isMacOS &&
      entity is Directory &&
      FileTypes.isMacPackage(entity.path);

  /// Whether [entity] gets a package's icon and kind: a macOS package, or
  /// an installer file (a flat .pkg), which macOS treats the same way.
  static bool _looksLikePackage(FileSystemEntity entity) =>
      isPackage(entity) ||
      (Platform.isMacOS &&
          entity is File &&
          FileTypes.macInstaller.contains(FileTypes.extensionOf(entity.path)));

  /// What Finder calls each of [FileTypes.macPackage] and
  /// [FileTypes.macInstaller]; one added there needs a name here too.
  static const _packageKinds = {
    // Apps, extensions and plug-ins
    'app': 'Application',
    'appex': 'App extension',
    'bundle': 'Bundle',
    'plugin': 'Plug-in',
    'kext': 'Kernel extension',
    'prefpane': 'Settings pane',
    'qlgenerator': 'Quick Look generator',
    'mdimporter': 'Spotlight importer',
    'saver': 'Screen saver',
    'wdgt': 'Widget',
    'xpc': 'XPC service',
    'component': 'Audio plug-in',
    'scptd': 'Script bundle',
    'workflow': 'Automator workflow',
    'action': 'Automator action',
    // Documents and libraries
    'rtfd': 'Rich text with attachments',
    'pages': 'Pages document',
    'numbers': 'Numbers spreadsheet',
    'key': 'Keynote presentation',
    'photoslibrary': 'Photos library',
    'photolibrary': 'iPhoto library',
    'musiclibrary': 'Music library',
    'imovielibrary': 'iMovie library',
    'theater': 'iMovie Theater',
    'fcpbundle': 'Final Cut Pro library',
    'logicx': 'Logic Pro project',
    'band': 'GarageBand project',
    'xcarchive': 'Xcode archive',
    'xcodeproj': 'Xcode project',
    'xcworkspace': 'Xcode workspace',
    'playground': 'Xcode playground',
    'docset': 'Documentation set',
    'mlpackage': 'Core ML package',
    'sparsebundle': 'Disk image',
    'download': 'Safari download',
    // Installers
    'pkg': 'Installer package',
    'mpkg': 'Installer package',
  };

  /// "2 KB · Today, 2:05 PM" for files, the date for folders and packages
  /// (whose size would need adding up what's inside).
  static String summary(FileSystemEntity entity, FileStat stat) {
    final modified = date(stat.modified);
    return entity is Directory ? modified : '${size(stat.size)} · $modified';
  }
}

/// Builds with the entity's [FileStat] (null until it has loaded).
class EntityStatBuilder extends StatefulWidget {
  const EntityStatBuilder({
    super.key,
    required this.entity,
    required this.builder,
  });

  final FileSystemEntity entity;
  final Widget Function(BuildContext context, FileStat? stat) builder;

  @override
  State<EntityStatBuilder> createState() => _EntityStatBuilderState();
}

class _EntityStatBuilderState extends State<EntityStatBuilder> {
  FileStat? _stat;

  @override
  void initState() {
    super.initState();
    _resolve();
  }

  @override
  void didUpdateWidget(EntityStatBuilder oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.entity, widget.entity)) _resolve();
  }

  void _resolve() {
    final entity = widget.entity;
    _stat = EntityStats.peek(entity);
    if (_stat != null) return;
    EntityStats.load(entity).then((stat) {
      if (mounted && identical(widget.entity, entity) && stat != null) {
        setState(() => _stat = stat);
      }
    });
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, _stat);
}

/// [FileIcon] / [FolderIcon] in an exact [size]×[size] box. The folder SVG
/// is wider than tall and would otherwise be laid out 1.26× wider than
/// [size], pushing folder names out of line with file names. macOS
/// packages get a file-like icon, as in Finder.
class EntityIcon extends StatelessWidget {
  const EntityIcon({super.key, required this.entity, this.size = 40});

  final FileSystemEntity entity;
  final double size;

  @override
  Widget build(BuildContext context) {
    return SizedBox.square(
      dimension: size,
      child: FileIcon(
        path: entity.path,
        size: size,
        isDirectory: entity is Directory && !EntityFormat.isPackage(entity),
        isPackage: EntityFormat._looksLikePackage(entity),
      ),
    );
  }
}
