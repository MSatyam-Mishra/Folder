import 'dart:io';
import 'package:archive/archive_io.dart';
import 'package:folders/core/files/file_types.dart';
import 'package:folders/core/platform/desktop.dart';
import 'package:folders/core/services/bluetooth_share.dart';
import 'package:folders/core/services/new_files.dart';
import 'package:folders/core/services/trash/trash.dart';
import 'package:folders/features/clipboard/bloc/clipboard_bloc.dart';
import 'package:folders/features/explorer_tabs/explorer_tabs.dart';
import 'package:folders/features/file_explorere/bloc/file_explorer_bloc.dart';
import 'package:folders/features/file_explorere/widgets/entity_meta.dart';
import 'package:folders/features/file_explorere/widgets/explorer_menu.dart';
import 'package:folders/features/file_explorere/widgets/checksum_panel.dart';
import 'package:folders/features/file_explorere/widgets/image_actions.dart';
import 'package:folders/features/file_explorere/widgets/info_row.dart';
import 'package:folders/features/tags/tag_actions.dart';
import 'package:folders/shared/ui/app_ui.dart';

import 'package:filesize/filesize.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shadcn_ui/shadcn_ui.dart' show LucideIcons;
import 'package:share_plus/share_plus.dart';

import 'package:folders/core/repositories/file_repository.dart';
import 'package:folders/core/router/file_opener.dart';
import 'package:folders/features/localsend/screens/localsend_screen.dart';
import 'package:folders/features/network/screens/file_server_screen.dart';
import 'package:folders/features/trash/trash_actions.dart';
import 'package:folders/features/vault/vault_store.dart';
import 'package:folders/features/panes/pane_menu.dart';
import 'package:folders/core/services/device_files.dart';

class FileActionsService {
  final FileRepository repository;

  FileActionsService({FileRepository? repository})
    : repository = repository ?? LocalFileRepository();

  /// "Ctrl+C" on Windows and Linux, "⌘C" on macOS.
  static String shortcut(String key, {bool modifier = true}) {
    if (!modifier) return key;
    return Platform.isMacOS ? '⌘$key' : 'Ctrl+$key';
  }

  /// The delete shortcut: the Delete key, or ⌘⌫ on macOS (Finder's Move to
  /// Trash; a Mac's delete key is backspace).
  static String get deleteShortcut => Platform.isMacOS ? '⌘⌫' : 'Delete';

  /// Deleting for good, past the Trash: Shift+Delete, or ⌥⌘⌫ on macOS.
  static String get deleteForGoodShortcut => Platform.isMacOS ? '⌥⌘⌫' : 'Shift+Delete';

  /// Whether [entity] is a macOS package (an app, plug-in or document
  /// package): a folder that opens like a file, as in Finder.
  static bool isPackage(FileSystemEntity entity) =>
      Platform.isMacOS && entity is Directory && FileTypes.isMacPackage(entity.path);

  /// Whether macOS opens [entity] itself, as Finder does: a package, or an
  /// installer file (.pkg), which opens in Installer.
  static bool opensWithMac(FileSystemEntity entity) =>
      isPackage(entity) ||
      (Platform.isMacOS &&
          entity is File &&
          FileTypes.macInstaller.contains(FileTypes.extensionOf(entity.path)));

  /// Starts macOS's `open` for a package; tests replace it.
  @visibleForTesting
  static Future<bool> Function(String path) packageLauncher =
      (path) async => (await Process.run('/usr/bin/open', [path])).exitCode == 0;

  /// Opens [entity] with macOS (launches an app, opens a document package
  /// in its app, an installer in Installer), as a double-click in Finder
  /// does.
  Future<void> openPackage(BuildContext context, FileSystemEntity entity) async {
    var opened = false;
    try {
      opened = await packageLauncher(entity.path);
    } catch (_) {}
    if (!opened && context.mounted) {
      _toast(context, "Couldn't open ${p.basename(entity.path)}");
    }
  }

  /// Desktop right-click menu for [entity] at [position], with the actions
  /// of [showFileOptionsMenu]. [onOpen] opens it as a click would;
  /// [onShowContents] browses inside a macOS package; [onShowInFolder] goes
  /// to its folder. [protected] leaves out moving, renaming and deleting
  /// (This PC's drives and libraries).
  Future<void> showContextMenu(
    BuildContext context,
    FileSystemEntity entity,
    Offset position, {
    required VoidCallback onOpen,
    VoidCallback? onShowContents,
    VoidCallback? onShowInFolder,
    bool protected = false,
    /// Rows the browser adds after Cut ("Copy to other pane").
    List<PaneMenuAction> extras = const [],
  }) async {
    final isFile = entity is File;
    final package = isPackage(entity);
    final images = ImageActions.imagesIn([entity]);
    final imageEntries = images.isEmpty ? const <PopupMenuEntry<Object>>[] : await ImageActions.menuEntries(context, images);
    if (!context.mounted) return;
    final tagEntry = protected ? null : await TagActions.menuEntry(context, [entity.path]);
    if (!context.mounted) return;
    final action = await ExplorerMenu.showAt<Object>(
      context,
      position,
      items: [
        ExplorerMenu.item(context,
            value: _EntityAction.open,
            label: 'Open',
            icon: isFile || package ? LucideIcons.fileInput : LucideIcons.folderOpen,
            shortcut: 'Enter'),
        if (package && onShowContents != null)
          ExplorerMenu.item(context,
              value: _EntityAction.showContents,
              label: 'Show package contents',
              icon: LucideIcons.packageOpen),
        if (!isFile && !package && ExplorerTabs.instance.enabled)
          ExplorerMenu.item(context,
              value: _EntityAction.newTab,
              label: 'Open in new tab',
              icon: LucideIcons.squarePlus),
        if (Desktop.isDesktop && !package)
          ExplorerMenu.item(context,
              value: _EntityAction.newWindow,
              label: 'Open in new window',
              icon: LucideIcons.appWindow),
        if (isFile)
          ExplorerMenu.item(context,
              value: _EntityAction.openWith,
              label: 'Open with…',
              icon: LucideIcons.squareArrowOutUpRight),
        if (onShowInFolder != null)
          ExplorerMenu.item(context,
              value: _EntityAction.showInFolder,
              label: 'Show in folder',
              icon: LucideIcons.folderSearch),
        if (imageEntries.isNotEmpty) ...[
          ExplorerMenu.divider(),
          ...imageEntries,
        ],
        ExplorerMenu.divider(),
        if (!protected) ...[
          ExplorerMenu.item(context,
              value: _EntityAction.copy,
              label: 'Copy',
              icon: LucideIcons.copy,
              shortcut: shortcut('C')),
          ExplorerMenu.item(context,
              value: _EntityAction.cut,
              label: 'Cut',
              icon: LucideIcons.scissors,
              shortcut: shortcut('X')),
          for (final extra in extras)
            ExplorerMenu.item<Object>(context,
                value: extra, label: extra.label, icon: extra.icon, shortcut: extra.shortcut),
          ExplorerMenu.item(context,
              value: _EntityAction.rename,
              label: 'Rename',
              icon: LucideIcons.pencil,
              shortcut: 'F2'),
          ExplorerMenu.divider(),
        ],
        ?tagEntry,
        ExplorerMenu.divider(),
        shareSubmenu(context, [entity],
            label: isFile ? 'Share file' : 'Share folder'),
        if (isFile && VaultStore.supported)
          ExplorerMenu.item(context,
              value: _EntityAction.vault,
              label: 'Move to vault',
              icon: LucideIcons.lockKeyhole),
        ExplorerMenu.item(context,
            value: _EntityAction.properties,
            label: 'Properties',
            icon: LucideIcons.info,
            shortcut: Platform.isMacOS ? '⌘I' : 'Alt+Enter'),
        if (!protected) ...[
          ExplorerMenu.divider(),
          ExplorerMenu.item(context,
              value: _EntityAction.delete,
              label: 'Delete',
              icon: LucideIcons.trash2,
              destructive: true,
              shortcut: deleteShortcut),
          if (Trash.instance.canTrash(entity.path))
            ExplorerMenu.item(context,
                value: _EntityAction.deleteForGood,
                label: 'Delete for good',
                icon: LucideIcons.fileX,
                destructive: true,
                shortcut: deleteForGoodShortcut),
        ],
      ],
    );
    if (action == null || !context.mounted) return;
    if (action is PaneMenuAction) return action.run();
    if (action is ShareMethod) return shareVia(context, action, [entity]);
    if (await ImageActions.handle(context, action, images) || !context.mounted) return;
    if (await TagActions.handle(context, action, [entity.path]) || !context.mounted) return;
    switch (action as _EntityAction) {
      case _EntityAction.open:
        onOpen();
      case _EntityAction.showContents:
        onShowContents?.call();
      case _EntityAction.showInFolder:
        onShowInFolder?.call();
      case _EntityAction.newTab:
        ExplorerTabs.instance.open(entity.path);
      case _EntityAction.newWindow:
        await (isFile
            ? Desktop.openWindow(file: entity.path)
            : Desktop.openWindow(folder: entity.path));
      case _EntityAction.openWith:
        await FileOpener.showOpenWith(context, entity as File);
      case _EntityAction.copy:
        context.read<ClipboardBloc>().add(CopyToClipboard([entity]));
        _toast(context, 'Copied. Open a folder and paste.');
      case _EntityAction.cut:
        context.read<ClipboardBloc>().add(CutToClipboard([entity]));
        _toast(context, 'Cut. Open a folder and paste.');
      case _EntityAction.rename:
        await showRenameDialog(context, entity);
      case _EntityAction.vault:
        await moveToVault(context, entity as File);
      case _EntityAction.properties:
        showInfoSheet(entity, context);
      case _EntityAction.delete:
        await deleteFiles(context, [entity]);
      case _EntityAction.deleteForGood:
        await deleteFiles(context, [entity], permanent: true);
    }
  }

  /// "Share ▸" in a right-click menu: over Wi-Fi as a web link (HTTP) or
  /// FTP, with LocalSend, over Bluetooth, or to other apps. Its items have
  /// [ShareMethod] values; pass the one chosen to [shareVia].
  PopupMenuEntry<Object> shareSubmenu(
    BuildContext context,
    List<FileSystemEntity> entities, {
    String label = 'Share',
  }) {
    return ExplorerMenu.submenu<Object>(
      context,
      label: label,
      icon: LucideIcons.share2,
      items: [
        ExplorerMenu.item(context,
            value: ShareMethod.web,
            label: 'Web link on Wi-Fi (HTTP)',
            icon: LucideIcons.globe),
        ExplorerMenu.item(context,
            value: ShareMethod.ftp,
            label: 'FTP server',
            icon: LucideIcons.server),
        ExplorerMenu.item(context,
            value: ShareMethod.localSend,
            label: 'LocalSend (nearby devices)',
            icon: LucideIcons.radio),
        if (BluetoothShare.available)
          ExplorerMenu.item(context,
              value: ShareMethod.bluetooth,
              label: 'Bluetooth',
              icon: LucideIcons.bluetooth,
              enabled: entities.any((e) => e is File)),
        if (Desktop.canShareFiles)
          ExplorerMenu.item(context,
              value: ShareMethod.apps,
              label: Platform.isWindows ? 'Nearby sharing and apps…' : 'Other apps…',
              icon: LucideIcons.squareArrowOutUpRight),
      ],
    );
  }

  /// Shares [entities] (from one folder) the way chosen in [shareSubmenu].
  Future<void> shareVia(
    BuildContext context,
    ShareMethod method,
    List<FileSystemEntity> entities,
  ) async {
    if (entities.isEmpty) return;
    switch (method) {
      case ShareMethod.web || ShareMethod.ftp:
        // A folder is shared whole; files only themselves, not their
        // neighbours.
        final folder = entities.length == 1 && entities.single is Directory;
        await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => FileServerScreen(
              initialFolder: folder ? entities.single.path : p.dirname(entities.first.path),
              only: folder ? null : [for (final e in entities) e.path],
              protocol: method == ShareMethod.ftp ? ShareProtocol.ftp : ShareProtocol.http,
              startNow: true,
            ),
          ),
        );
      case ShareMethod.localSend:
        await Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => LocalSendScreen(initialItems: entities)),
        );
      case ShareMethod.bluetooth:
        final files = [for (final e in entities) if (e is File) e.path];
        if (files.isEmpty) {
          _toast(context, 'Bluetooth sends files, not folders.');
          return;
        }
        if (files.length != entities.length) {
          _toast(context, 'Folders were skipped: Bluetooth sends files only.');
        }
        try {
          await BluetoothShare.send(files);
        } catch (e) {
          if (context.mounted) _toast(context, "Couldn't open Bluetooth: $e");
        }
      case ShareMethod.apps:
        shareMany(context, entities);
    }
  }

  // Method to show the main options menu
  void showFileOptionsMenu(BuildContext context, FileSystemEntity entity) {
    AppSheet.show<void>(
      context,
      child: Builder(
        builder: (sheetContext) {
          void run(VoidCallback action) {
            Navigator.pop(sheetContext);
            action();
          }

          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _EntityHeader(entity: entity),
              const SizedBox(height: 12),
              if (entity is File)
                _SheetAction(
                  icon: LucideIcons.squareArrowOutUpRight,
                  label: 'Open with…',
                  onTap: () =>
                      run(() => FileOpener.showOpenWith(context, entity)),
                ),
              if (Desktop.canShareFiles)
                _SheetAction(
                  icon: LucideIcons.share2,
                  label: 'Share',
                  onTap: () => run(() => share(context, entity)),
                ),
              if (ImageActions.imagesIn([entity]).isNotEmpty) ...[
                _SheetAction(
                  icon: LucideIcons.fileImage,
                  label: 'Convert to…',
                  detail: 'PNG, JPEG, WebP, HEIC…',
                  onTap: () => run(() => ImageActions.chooseFormat(context, [entity.path])),
                ),
                _SheetAction(
                  icon: LucideIcons.scaling,
                  label: 'Resize…',
                  onTap: () => run(() => ImageActions.resize(context, [entity.path])),
                ),
              ],
              _SheetAction(
                icon: LucideIcons.radio,
                label: 'Send nearby',
                detail: 'LocalSend',
                onTap: () => run(
                  () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => LocalSendScreen(initialItems: [entity]),
                    ),
                  ),
                ),
              ),
              if (entity is File && VaultStore.supported)
                _SheetAction(
                  icon: LucideIcons.lockKeyhole,
                  label: 'Move to vault',
                  detail: Platform.isAndroid
                      ? 'Hide it from other apps'
                      : 'Move it out of your folders',
                  onTap: () => run(() => moveToVault(context, entity)),
                ),
              const _SheetDivider(),
              _SheetAction(
                icon: LucideIcons.copy,
                label: 'Copy',
                onTap: () => run(() {
                  context.read<ClipboardBloc>().add(CopyToClipboard([entity]));
                  _toast(context, 'Copied. Open a folder and paste.');
                }),
              ),
              _SheetAction(
                icon: LucideIcons.scissors,
                label: 'Cut',
                onTap: () => run(() {
                  context.read<ClipboardBloc>().add(CutToClipboard([entity]));
                  _toast(context, 'Cut. Open a folder and paste.');
                }),
              ),
              _SheetAction(
                icon: LucideIcons.pencil,
                label: 'Rename',
                onTap: () => run(() => showRenameDialog(context, entity)),
              ),
              _SheetAction(
                icon: LucideIcons.tag,
                label: 'Tags',
                onTap: () => run(() => TagActions.showPicker(context, [entity.path])),
              ),
              _SheetAction(
                icon: LucideIcons.info,
                label: 'Properties',
                onTap: () => run(() => showInfoSheet(entity, context)),
              ),
              const _SheetDivider(),
              _SheetAction(
                icon: LucideIcons.trash2,
                label: 'Delete',
                destructive: true,
                onTap: () => run(() => deleteFiles(context, [entity])),
              ),
              if (Trash.instance.canTrash(entity.path))
                _SheetAction(
                  icon: LucideIcons.fileX,
                  label: 'Delete for good',
                  destructive: true,
                  onTap: () => run(() => deleteFiles(context, [entity], permanent: true)),
                ),
            ],
          );
        },
      ),
    );
  }

  /// Asks for a file or folder name. Returns the trimmed name, or null when
  /// cancelled. With [selectBaseName] the part before the extension starts
  /// selected (renaming files).
  Future<String?> promptForName(
    BuildContext context, {
    required String title,
    required String confirmLabel,
    String? description,
    String initialValue = '',
    bool selectBaseName = false,
    String? Function(String name)? validator,
  }) {
    return showDialog<String>(
      context: context,
      builder: (_) => _NameDialog(
        title: title,
        description: description,
        confirmLabel: confirmLabel,
        initialValue: initialValue,
        selectBaseName: selectBaseName,
        validator: validator,
      ),
    );
  }

  Future<void> showRenameDialog(
    BuildContext blocContext,
    FileSystemEntity entity,
  ) async {
    final oldName = p.basename(entity.path);
    final isDirectory = entity is Directory;
    final newName = await promptForName(
      blocContext,
      title: isDirectory ? 'Rename folder' : 'Rename file',
      confirmLabel: 'Rename',
      initialValue: oldName,
      selectBaseName: !isDirectory,
      validator: (name) {
        if (name == oldName) return '';
        final target = p.join(entity.parent.path, name);
        // On Windows and macOS "report.pdf" and "Report.pdf" are the same
        // file: changing only the case is a rename, not a clash.
        if ((File(target).existsSync() || Directory(target).existsSync()) &&
            !FileSystemEntity.identicalSync(entity.path, target)) {
          return 'An item with this name already exists.';
        }
        return null;
      },
    );

    if (newName != null && newName.isNotEmpty && newName != oldName) {
      try {
        final newPath = p.join(entity.parent.path, newName);
        await repository.rename(entity.path, newPath);
        if (!blocContext.mounted) return;
        // Use the passed-in blocContext, which is guaranteed to have the BLoC
        final currentState = blocContext.read<FileExplorerBloc>().state;
        if (currentState is FileExplorerLoaded) {
          blocContext.read<FileExplorerBloc>().add(
            LoadDirectory(currentState.path),
          );
        }
      } catch (e) {
        debugPrint('Error renaming: $e');
        if (blocContext.mounted) {
          _toast(blocContext, "Couldn't rename \"$oldName\": ${_reason(e)}");
        }
      }
    }
  }

  /// Makes a folder in [parentPath] and starts renaming it where it's shown,
  /// as File Explorer does.
  Future<void> createFolder(
    BuildContext blocContext,
    String parentPath,
  ) async {
    final bloc = blocContext.read<FileExplorerBloc>();
    final path = p.join(parentPath, NewFiles.freeName(parentPath, 'New folder', ''));
    try {
      await repository.createDirectory(path);
      // A search under way wouldn't show it.
      final current = bloc.state;
      if (current is FileExplorerLoaded && current.searchOpen) bloc.add(CloseSearch());
      bloc.add(LoadDirectory(parentPath, select: path, rename: true));
    } catch (e) {
      debugPrint('Error creating folder: $e');
      if (blocContext.mounted) {
        _toast(blocContext, "Couldn't create the folder: ${_reason(e)}");
      }
    }
  }

  /// The name typed where [entity] is shown: [name], or null to keep its own.
  Future<void> finishRename(
    BuildContext blocContext,
    FileSystemEntity entity,
    String? name,
  ) async {
    final bloc = blocContext.read<FileExplorerBloc>();
    final oldName = p.basename(entity.path);
    bloc.add(StopRenaming());
    if (name == null || name.isEmpty || name == oldName) return;
    if (name == '.' || name == '..' || RegExp(r'[\\/:*?"<>|]').hasMatch(name)) {
      _toast(blocContext, '"$name" can\'t be a name. Kept "$oldName".');
      return;
    }
    final parent = entity.parent.path;
    final target = p.join(parent, name);
    // On Windows and macOS changing only the case is a rename, not a clash.
    if (FileSystemEntity.typeSync(target) != FileSystemEntityType.notFound &&
        !FileSystemEntity.identicalSync(entity.path, target)) {
      _toast(blocContext, 'An item named "$name" already exists. Kept "$oldName".');
      return;
    }
    try {
      await repository.rename(entity.path, target);
      bloc.add(LoadDirectory(parent, select: target));
    } catch (e) {
      debugPrint('Error renaming: $e');
      if (blocContext.mounted) {
        _toast(blocContext, "Couldn't rename \"$oldName\": ${_reason(e)}");
      }
    }
  }

  /// Opens a new file of [kind] in its editor. It's not in [folder], and has no
  /// name, until its first save asks for one; left unsaved, nothing is made.
  Future<void> startNewFile(
    BuildContext blocContext,
    String folder,
    NewFileKind kind,
  ) async {
    if (kind.editor == NewFileEditor.none) {
      return _createThenOpen(blocContext, folder, kind);
    }
    final bloc = blocContext.read<FileExplorerBloc>();
    UntitledFile? untitled;
    try {
      untitled = await UntitledFiles.start(kind, folder, _askNewFileName);
      if (!blocContext.mounted) return;
      await (kind.editor == NewFileEditor.text
          ? FileOpener.openAs(blocContext, untitled.file, FileKind.text)
          : FileOpener.open(blocContext, untitled.file));
    } catch (e) {
      debugPrint('Error starting a new file: $e');
      if (blocContext.mounted) {
        _toast(blocContext, "Couldn't create the file: ${_reason(e)}");
      }
    } finally {
      await untitled?.close();
      final saved = untitled?.savedPath;
      if (saved != null && !bloc.isClosed) bloc.add(LoadDirectory(folder, select: saved));
    }
  }

  /// The name of a new file, asked at its first save. Its extension is added
  /// if left out; only text may change to another one, as the other editors
  /// write their own format.
  Future<String?> _askNewFileName(BuildContext context, UntitledFile untitled) async {
    final kind = untitled.kind;
    String complete(String name) {
      final extension = p.extension(name).toLowerCase();
      final fine = kind.editor == NewFileEditor.text ? extension.isNotEmpty : extension == '.${kind.extension}';
      return fine ? name : '$name.${kind.extension}';
    }

    final name = await promptForName(
      context,
      title: 'Save as',
      description: 'In ${untitled.folder}',
      confirmLabel: 'Save',
      initialValue: NewFiles.freeName(untitled.folder, kind.baseName, kind.extension),
      selectBaseName: true,
      validator: (name) => FileSystemEntity.typeSync(p.join(untitled.folder, complete(name))) !=
              FileSystemEntityType.notFound
          ? 'An item with this name already exists.'
          : null,
    );
    return name == null || name.isEmpty ? null : complete(name);
  }

  /// For kinds with no editor to type in (a PDF, a picture, an archive): asks
  /// for a name, creates the blank file and shows it.
  Future<void> _createThenOpen(
    BuildContext blocContext,
    String parentPath,
    NewFileKind kind,
  ) async {
    final name = await promptForName(
      blocContext,
      title: 'New ${kind.label}',
      confirmLabel: 'Create',
      initialValue: NewFiles.freeName(parentPath, kind.baseName, kind.extension),
      selectBaseName: true,
      validator: (name) {
        if (FileSystemEntity.typeSync(p.join(parentPath, name)) != FileSystemEntityType.notFound) {
          return 'An item with this name already exists.';
        }
        return null;
      },
    );
    if (name == null || name.isEmpty) return;
    try {
      final path = p.join(parentPath, name);
      await NewFiles.create(kind, path);
      if (!blocContext.mounted) return;
      blocContext.read<FileExplorerBloc>().add(LoadDirectory(parentPath, select: path));
      await FileOpener.open(blocContext, File(path));
    } catch (e) {
      debugPrint('Error creating file: $e');
      if (blocContext.mounted) {
        _toast(blocContext, "Couldn't create the file: ${_reason(e)}");
      }
    }
  }

  Future<void> showDeleteConfirmationDialog(
    BuildContext blocContext,
    FileSystemEntity entity,
  ) async {
    final name = p.basename(entity.path);
    final confirmed = await _confirmDelete(
      blocContext,
      title: 'Delete "$name"?',
      message: entity is Directory
          ? 'This folder and everything in it will be permanently deleted. '
              "This can't be undone."
          : "This file will be permanently deleted. This can't be undone.",
    );

    if (confirmed == true) {
      try {
        await repository.delete(entity.path, recursive: true);
        if (!blocContext.mounted) return;
        final currentState = blocContext.read<FileExplorerBloc>().state;
        if (currentState is FileExplorerLoaded) {
          blocContext.read<FileExplorerBloc>().add(
            LoadDirectory(currentState.path),
          );
        }
      } catch (e) {
        debugPrint('Error deleting: $e');
        if (blocContext.mounted) {
          _toast(blocContext, "Couldn't delete \"$name\": ${_reason(e)}");
        }
      }
    }
  }

  /// Deletes [files]: to the Trash, with Undo, unless [permanent] or they
  /// can't go there; then for good, after asking.
  Future<void> deleteFiles(
    BuildContext context,
    List<FileSystemEntity> files, {
    bool permanent = false,
  }) async {
    if (files.isEmpty) return;
    if (!permanent && await TrashActions.moveToTrash(context, files)) return;
    if (!context.mounted) return;
    if (files.length == 1) {
      await showDeleteConfirmationDialog(context, files.single);
      if (context.mounted) {
        context.read<FileExplorerBloc>().add(ToggleSelectionMode(enable: false));
      }
      return;
    }

    final confirmed = await _confirmDelete(
      context,
      title: 'Delete ${files.length} items?',
      message: "The selected items will be permanently deleted. This can't be "
          'undone.',
    );

    if (confirmed == true) {
      int successCount = 0;
      for (final file in files) {
        try {
          await repository.delete(file.path, recursive: true);
          successCount++;
        } catch (e) {
          debugPrint('Error deleting ${file.path}: $e');
        }
      }

      if (context.mounted) {
        final failed = files.length - successCount;
        _toast(
          context,
          failed == 0
              ? 'Deleted $successCount items'
              : "Deleted $successCount items. $failed couldn't be deleted.",
        );

        final currentState = context.read<FileExplorerBloc>().state;
        if (currentState is FileExplorerLoaded) {
          context.read<FileExplorerBloc>().add(
            LoadDirectory(currentState.path),
          );
          context.read<FileExplorerBloc>().add(
            ToggleSelectionMode(enable: false),
          );
        }
      }
    }
  }

  Future<bool?> _confirmDelete(
    BuildContext context, {
    required String title,
    required String message,
  }) {
    return showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        final colors = dialogContext.colors;
        return AlertDialog(
          title: Text(title),
          content: Text(message),
          actions: [
            OutlinedButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: colors.destructive,
                foregroundColor: colors.destructiveForeground,
              ),
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('Delete'),
            ),
          ],
        );
      },
    );
  }

  /// Moves [file] into the vault and refreshes the folder.
  Future<void> moveToVault(BuildContext blocContext, File file) async {
    final name = p.basename(file.path);
    try {
      await VaultStore().add(file);
      DeviceFiles.invalidate();
      if (!blocContext.mounted) return;
      _toast(blocContext, 'Moved "$name" to the vault');
      final bloc = blocContext.read<FileExplorerBloc>();
      final state = bloc.state;
      if (state is FileExplorerLoaded) bloc.add(LoadDirectory(state.path));
    } catch (e) {
      debugPrint('Error moving to vault: $e');
      if (blocContext.mounted) {
        _toast(blocContext, "Couldn't move \"$name\" to the vault: ${_reason(e)}");
      }
    }
  }

  void showInfoSheet(FileSystemEntity entity, BuildContext context) {
    AppSheet.show<void>(context, style: SheetStyle.side, child: _PropertiesSheet(entity: entity));
  }

  static Future<int> calculateDirectorySize(Directory dir) async =>
      (await _scanDirectory(dir)).bytes;

  /// Total size and number of files / folders under [dir]; unreadable
  /// sub-folders are skipped.
  static Future<({int bytes, int files, int folders})> _scanDirectory(
    Directory dir,
  ) async {
    var bytes = 0;
    var files = 0;
    var folders = 0;
    await for (final entity in dir
        .list(recursive: true, followLinks: false)
        .handleError((Object _) {})) {
      if (entity is File) {
        files++;
        try {
          bytes += (await entity.stat()).size;
        } catch (_) {}
      } else if (entity is Directory) {
        folders++;
      }
    }
    return (bytes: bytes, files: files, folders: folders);
  }

  /// Anchor for the iPad share popover: the widget that triggered the
  /// share, or the middle of the screen.
  static Rect _shareOrigin(BuildContext context) {
    final box = context.findRenderObject();
    if (box is RenderBox && box.attached && box.hasSize) {
      return box.localToGlobal(Offset.zero) & box.size;
    }
    final size = MediaQuery.sizeOf(context);
    return Rect.fromCenter(center: size.center(Offset.zero), width: 1, height: 1);
  }

  Future<void> share(BuildContext context, FileSystemEntity entity) async {
    if (entity is File) {
      await _shareFiles(context, [XFile(entity.path)]);
    } else if (entity is Directory) {
      await shareZippedFolder(context, entity);
    }
  }

  /// Shares [files], saying so when the system can't.
  Future<void> _shareFiles(BuildContext context, List<XFile> files) async {
    try {
      await SharePlus.instance.share(ShareParams(
        files: files,
        sharePositionOrigin: _shareOrigin(context),
      ));
    } catch (e) {
      if (context.mounted) _toast(context, "Couldn't share: $e");
    }
  }

  /// Shares several items at once. A single folder is zipped first; with
  /// several items, folders are skipped.
  void shareMany(BuildContext context, List<FileSystemEntity> entities) {
    if (entities.isEmpty) return;
    if (entities.length == 1) {
      share(context, entities.single);
      return;
    }
    final files = entities.whereType<File>().toList();
    if (files.isEmpty) {
      _toast(context, 'Folders can only be shared one at a time.');
      return;
    }
    if (files.length != entities.length) {
      _toast(context, 'Folders were skipped. Share them one at a time.');
    }
    _shareFiles(context, [for (final f in files) XFile(f.path)]);
  }

  Future<void> shareZippedFolder(
    BuildContext context,
    Directory directory,
  ) async {
    final origin = _shareOrigin(context);
    // Show a loading indicator
    _toast(context, 'Zipping folder for sharing…');

    Directory? shareDir;
    var shared = false;
    final encoder = ZipFileEncoder();

    try {
      shareDir = await newShareDir(await getTemporaryDirectory());
      final zipPath = p.join(shareDir.path, '${p.basename(directory.path)}.zip');
      encoder.create(zipPath);
      await for (final entity in directory.list(
        recursive: true,
        followLinks: false,
      )) {
        if (entity is File) {
          final relativePath = p.relative(entity.path, from: directory.path);
          await encoder.addFile(entity, relativePath);
        }
      }
      await encoder.close();

      // Share the created ZIP file
      await SharePlus.instance.share(ShareParams(
        files: [XFile(zipPath)],
        text: 'Sharing folder: ${p.basename(directory.path)}',
        sharePositionOrigin: origin,
      ));
      shared = true;
    } catch (e) {
      if (context.mounted) {
        _toast(context, "Couldn't zip the folder: ${_reason(e)}");
      }
    } finally {
      // share() returns once an app is chosen. On macOS the app reads the
      // zip later (AirDrop waits for a device to accept), so it stays until
      // a later share sweeps it.
      if (shareDir != null && (!Platform.isMacOS || !shared)) {
        try {
          await shareDir.delete(recursive: true);
        } catch (_) {}
      }
    }
  }

  /// Shared folders are zipped into folders under this one in the
  /// temporary directory.
  static const _shareDirName = 'explorer_share';

  /// Zips kept from a share this long ago are no longer being read.
  static const _shareKeep = Duration(hours: 1);

  /// A new folder under [temp] for one shared folder's zip. Zips of shares
  /// older than an hour are swept first; newer ones may still be zipping
  /// or waiting to be read.
  @visibleForTesting
  static Future<Directory> newShareDir(Directory temp, {DateTime? now}) async {
    final root = await Directory(p.join(temp.path, _shareDirName))
        .create(recursive: true);
    final cutoff = (now ?? DateTime.now()).subtract(_shareKeep);
    try {
      await for (final entity in root.list()) {
        try {
          if (await _untouchedSince(entity, cutoff)) {
            await entity.delete(recursive: true);
          }
        } catch (_) {
          // A zip another app still has open (Windows) stays behind.
        }
      }
    } catch (_) {}
    return root.createTemp('share');
  }

  /// Whether [entity] and what is directly in it last changed before
  /// [cutoff].
  static Future<bool> _untouchedSince(
    FileSystemEntity entity,
    DateTime cutoff,
  ) async {
    if (!(await entity.stat()).modified.isBefore(cutoff)) return false;
    if (entity is Directory) {
      await for (final child in entity.list()) {
        if (!(await child.stat()).modified.isBefore(cutoff)) return false;
      }
    }
    return true;
  }

  static void _toast(BuildContext context, String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  static String _reason(Object error) => switch (error) {
        FileSystemException(:final osError?) => osError.message,
        FileSystemException(:final message) => message,
        _ => error.toString(),
      };
}

/// File icon, name and "size · type · date" at the top of the sheets.
class _EntityHeader extends StatelessWidget {
  const _EntityHeader({required this.entity, this.iconSize = 40});

  final FileSystemEntity entity;
  final double iconSize;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final name = p.basename(entity.path);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Row(
        children: [
          EntityIcon(entity: entity, size: iconSize),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name.isEmpty ? entity.path : name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: text.titleSmall,
                ),
                const SizedBox(height: 2),
                EntityStatBuilder(
                  entity: entity,
                  builder: (context, stat) => Text(
                    [
                      if (stat != null && entity is File)
                        EntityFormat.size(stat.size),
                      EntityFormat.kind(entity),
                      if (stat != null) EntityFormat.date(stat.modified),
                    ].join(' · '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: text.bodySmall,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// A row in an action sheet (dropdown-menu style).
class _SheetAction extends StatelessWidget {
  const _SheetAction({
    required this.icon,
    required this.label,
    required this.onTap,
    this.detail,
    this.destructive = false,
  });

  final IconData icon;
  final String label;
  final String? detail;
  final VoidCallback onTap;
  final bool destructive;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final text = Theme.of(context).textTheme;
    final fg = destructive ? colors.destructive : colors.foreground;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: SizedBox(
        height: 44,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            children: [
              Icon(
                icon,
                size: 18,
                color: destructive ? colors.destructive : colors.mutedForeground,
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Text(
                  label,
                  style: text.bodyMedium?.copyWith(
                    color: fg,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              if (detail != null) Text(detail!, style: text.bodySmall),
            ],
          ),
        ),
      ),
    );
  }
}

class _SheetDivider extends StatelessWidget {
  const _SheetDivider();

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
        child: Divider(height: 1, color: context.colors.border),
      );
}

/// Name prompt used for rename, new folder and archive names.
class _NameDialog extends StatefulWidget {
  const _NameDialog({
    required this.title,
    required this.confirmLabel,
    required this.initialValue,
    required this.selectBaseName,
    this.description,
    this.validator,
  });

  final String title;
  final String? description;
  final String confirmLabel;
  final String initialValue;
  final bool selectBaseName;

  /// Returns an error message, '' to just disable the button, or null.
  final String? Function(String name)? validator;

  @override
  State<_NameDialog> createState() => _NameDialogState();
}

class _NameDialogState extends State<_NameDialog> {
  late final TextEditingController _controller;
  String? _error;
  bool _valid = false;

  static final _illegal = RegExp(r'[\\/:*?"<>|]');

  @override
  void initState() {
    super.initState();
    final value = widget.initialValue;
    final ext = p.extension(value);
    final end = widget.selectBaseName && ext.isNotEmpty && ext != value
        ? value.length - ext.length
        : value.length;
    _controller = TextEditingController(text: value)
      ..selection = TextSelection(baseOffset: 0, extentOffset: end);
    _validate(value);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _validate(String raw) {
    final name = raw.trim();
    String? error;
    if (name.isEmpty) {
      error = '';
    } else if (_illegal.hasMatch(name) || name == '.' || name == '..') {
      error = 'Names can\'t contain \\ / : * ? " < > |';
    } else {
      error = widget.validator?.call(name);
    }
    _valid = error == null;
    _error = error == null || error.isEmpty ? null : error;
  }

  void _submit() {
    if (_valid) Navigator.pop(context, _controller.text.trim());
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 400,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (widget.description != null) ...[
              Text(widget.description!),
              const SizedBox(height: 16),
            ],
            TextField(
              controller: _controller,
              autofocus: true,
              onChanged: (value) => setState(() => _validate(value)),
              onSubmitted: (_) => _submit(),
              style: Theme.of(context).textTheme.bodyMedium,
              decoration: InputDecoration(errorText: _error),
            ),
          ],
        ),
      ),
      actions: [
        OutlinedButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _valid ? _submit : null,
          child: Text(widget.confirmLabel),
        ),
      ],
    );
  }
}

/// Properties: type, size (folders are measured in the background),
/// location and dates.
class _PropertiesSheet extends StatefulWidget {
  const _PropertiesSheet({required this.entity});

  final FileSystemEntity entity;

  @override
  State<_PropertiesSheet> createState() => _PropertiesSheetState();
}

class _PropertiesSheetState extends State<_PropertiesSheet> {
  static final _dateTime = DateFormat.yMMMd().add_jm();

  late final Future<FileStat> _stat = widget.entity.stat();
  late final Future<({int bytes, int files, int folders})>? _scan =
      widget.entity is Directory
          ? FileActionsService._scanDirectory(widget.entity as Directory)
          : null;

  @override
  Widget build(BuildContext context) {
    final entity = widget.entity;
    final text = Theme.of(context).textTheme;
    final number = NumberFormat.decimalPattern();

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Properties', style: text.titleLarge),
        const SizedBox(height: 16),
        _EntityHeader(entity: entity, iconSize: 44),
        const SizedBox(height: 16),
        FutureBuilder<FileStat>(
          future: _stat,
          builder: (context, statSnap) {
            final stat = statSnap.data;
            return _DetailsCard(
              children: [
                InfoRow(title: 'Type', content: EntityFormat.kind(entity)),
                if (_scan != null)
                  FutureBuilder(
                    future: _scan,
                    builder: (context, snap) {
                      final scan = snap.data;
                      if (snap.hasError) {
                        return const InfoRow(title: 'Size', content: '—');
                      }
                      if (scan == null) {
                        return const InfoRow(
                          title: 'Size',
                          content: 'Calculating…',
                          muted: true,
                        );
                      }
                      return InfoRow(
                        title: 'Size',
                        content: '${filesize(scan.bytes, 1)} · '
                            '${number.format(scan.files)} '
                            '${scan.files == 1 ? 'file' : 'files'}, '
                            '${number.format(scan.folders)} '
                            '${scan.folders == 1 ? 'folder' : 'folders'}',
                      );
                    },
                  )
                else
                  InfoRow(
                    title: 'Size',
                    content: stat == null
                        ? '…'
                        : '${filesize(stat.size, 1)} '
                            '(${number.format(stat.size)} bytes)',
                  ),
                InfoRow(
                  title: 'Location',
                  content: entity.parent.path,
                  selectable: true,
                ),
                InfoRow(
                  title: 'Modified',
                  content: stat == null ? '…' : _dateTime.format(stat.modified),
                ),
                InfoRow(
                  title: 'Accessed',
                  content: stat == null ? '…' : _dateTime.format(stat.accessed),
                ),
                if (!Platform.isWindows && stat != null)
                  InfoRow(title: 'Permissions', content: stat.modeString()),
              ],
            );
          },
        ),
        if (entity is File) ...[
          const SizedBox(height: 20),
          ChecksumPanel(file: entity),
        ],
        const SizedBox(height: 16),
        OutlinedButton.icon(
          onPressed: () {
            Clipboard.setData(ClipboardData(text: entity.path));
            FileActionsService._toast(context, 'Path copied');
          },
          icon: const Icon(LucideIcons.copy, size: 16),
          label: const Text('Copy path'),
        ),
      ],
    );
  }
}

/// Bordered card with hairlines between its rows.
class _DetailsCard extends StatelessWidget {
  const _DetailsCard({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: colors.border),
      ),
      child: Column(
        children: [
          for (var i = 0; i < children.length; i++) ...[
            if (i > 0) Divider(height: 1, color: colors.border),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
              child: children[i],
            ),
          ],
        ],
      ),
    );
  }
}

/// Ways to share files, see [FileActionsService.shareSubmenu].
enum ShareMethod { web, ftp, localSend, bluetooth, apps }

enum _EntityAction {
  open,
  showContents,
  showInFolder,
  newTab,
  newWindow,
  openWith,
  copy,
  cut,
  rename,
  vault,
  properties,
  delete,
  deleteForGood,
}
