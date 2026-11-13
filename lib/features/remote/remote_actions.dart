import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:folders/core/router/file_opener.dart';
import 'package:folders/core/services/file_action_service.dart';
import 'package:folders/core/services/new_files.dart';
import 'package:folders/core/services/remote/remote_entities.dart';
import 'package:folders/core/services/remote/remote_fs.dart';
import 'package:folders/core/services/remote/remote_places.dart';
import 'package:folders/core/services/remote/remote_pool.dart';
import 'package:folders/features/file_explorere/bloc/file_explorer_bloc.dart';
import 'package:folders/features/remote/place_editor.dart';
import 'package:folders/features/remote/remote_open.dart';
import 'package:path/path.dart' as p;
import 'package:shadcn_ui/shadcn_ui.dart' show LucideIcons;

/// What the browser does its own way on network places: names are checked
/// against the folder's listing, not this device's disks, and new things
/// are made through the place's connection.
abstract final class RemoteActions {
  /// The decoded name of a browser path on a place.
  static String nameOf(String browserPath) => RemotePaths.nameOf(RemotePaths.parse(browserPath)?.$2 ?? '/');

  /// The names in the folder on screen, lower case.
  static Set<String> _taken(FileExplorerBloc bloc) {
    final state = bloc.state;
    return state is FileExplorerLoaded ? {for (final e in state.entities) nameOf(e.path).toLowerCase()} : {};
  }

  static String _free(Set<String> taken, String base, String extension) {
    final ending = extension.isEmpty ? '' : '.$extension';
    if (!taken.contains('$base$ending'.toLowerCase())) return '$base$ending';
    for (var i = 2;; i++) {
      final name = '$base ($i)$ending';
      if (!taken.contains(name.toLowerCase())) return name;
    }
  }

  static void _toast(BuildContext context, String message) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  static String _reason(Object error) => remoteError(error).message;

  static final _illegal = RegExp(r'[\\/:*?"<>|]');

  /// New folder: made at once, then renamed where it's shown.
  static Future<void> createFolder(BuildContext blocContext, String folder) async {
    final bloc = blocContext.read<FileExplorerBloc>();
    final (id, remote) = RemotePaths.parse(folder)!;
    final name = _free(_taken(bloc), 'New folder', '');
    final path = RemotePaths.join(remote, name);
    try {
      await RemotePool.instance.run(id, (fs) => fs.createDirectory(path));
      final current = bloc.state;
      if (current is FileExplorerLoaded && current.searchOpen) bloc.add(CloseSearch());
      bloc.add(LoadDirectory(folder, select: RemotePaths.build(id, path), rename: true));
    } catch (e) {
      if (blocContext.mounted) _toast(blocContext, "Couldn't create the folder: ${_reason(e)}");
    }
  }

  /// Rename (F2, menus): asks for the name in a dialog.
  static Future<void> rename(BuildContext blocContext, RemoteEntity entity, FileActionsService actions) async {
    final bloc = blocContext.read<FileExplorerBloc>();
    final oldName = entity.entry.name;
    final taken = _taken(bloc)..remove(oldName.toLowerCase());
    final name = await actions.promptForName(
      blocContext,
      title: entity.entry.isDirectory ? 'Rename folder' : 'Rename file',
      confirmLabel: 'Rename',
      initialValue: oldName,
      selectBaseName: !entity.entry.isDirectory,
      validator: (name) {
        if (name == oldName) return '';
        if (taken.contains(name.toLowerCase())) return 'An item with this name already exists.';
        return null;
      },
    );
    if (name == null || name.isEmpty || name == oldName || !blocContext.mounted) return;
    await _rename(blocContext, entity, name);
  }

  /// The name typed where [entity] is shown: [name], or null to keep its own.
  static Future<void> finishRename(BuildContext blocContext, RemoteEntity entity, String? name) async {
    final bloc = blocContext.read<FileExplorerBloc>();
    final oldName = entity.entry.name;
    bloc.add(StopRenaming());
    if (name == null || name.isEmpty || name == oldName) return;
    if (name == '.' || name == '..' || _illegal.hasMatch(name)) {
      _toast(blocContext, '"$name" can\'t be a name. Kept "$oldName".');
      return;
    }
    final taken = _taken(bloc)..remove(oldName.toLowerCase());
    if (taken.contains(name.toLowerCase())) {
      _toast(blocContext, 'An item named "$name" already exists. Kept "$oldName".');
      return;
    }
    await _rename(blocContext, entity, name);
  }

  static Future<void> _rename(BuildContext blocContext, RemoteEntity entity, String name) async {
    final bloc = blocContext.read<FileExplorerBloc>();
    final target = RemotePaths.join(RemotePaths.parentOf(entity.remotePath), name);
    try {
      await RemotePool.instance.run(entity.connectionId, (fs) => fs.rename(entity.remotePath, target));
      bloc.add(LoadDirectory(
        RemotePaths.build(entity.connectionId, RemotePaths.parentOf(entity.remotePath)),
        select: RemotePaths.build(entity.connectionId, target),
      ));
    } catch (e) {
      if (blocContext.mounted) _toast(blocContext, "Couldn't rename \"${entity.entry.name}\": ${_reason(e)}");
    }
  }

  /// A new file of [kind] in a place's [folder]: named first, made blank
  /// here, uploaded, then opened like any file there.
  static Future<void> newFile(
    BuildContext blocContext,
    String folder,
    NewFileKind kind,
    FileActionsService actions,
  ) async {
    final bloc = blocContext.read<FileExplorerBloc>();
    final taken = _taken(bloc);
    String complete(String name) {
      final extension = p.extension(name).toLowerCase();
      final fine = kind.editor == NewFileEditor.text ? extension.isNotEmpty : extension == '.${kind.extension}';
      return fine ? name : '$name.${kind.extension}';
    }

    final typed = await actions.promptForName(
      blocContext,
      title: 'New ${kind.label}',
      confirmLabel: 'Create',
      initialValue: _free(taken, kind.baseName, kind.extension),
      selectBaseName: true,
      validator: (name) => taken.contains(complete(name).toLowerCase()) ? 'An item with this name already exists.' : null,
    );
    if (typed == null || typed.isEmpty || !blocContext.mounted) return;
    final name = complete(typed);
    final (id, remote) = RemotePaths.parse(folder)!;
    final path = RemotePaths.join(remote, name);
    Directory? scratch;
    try {
      scratch = await Directory.systemTemp.createTemp('new_remote_file');
      final local = File(p.join(scratch.path, name));
      await NewFiles.create(kind, local.path);
      final length = await local.length();
      await RemotePool.instance.run(id, (fs) => fs.write(path, local.openRead(), length: length), retry: false);
      final entry = await RemotePool.instance.run(id, (fs) => fs.stat(path));
      bloc.add(LoadDirectory(folder, select: RemotePaths.build(id, path)));
      if (!blocContext.mounted) return;
      final opened = await FileOpener.open(blocContext, RemoteFile(id, entry));
      if (opened == true && !bloc.isClosed) bloc.add(LoadDirectory(folder));
    } catch (e) {
      if (blocContext.mounted) _toast(blocContext, "Couldn't create the file: ${_reason(e)}");
    } finally {
      try {
        await scratch?.delete(recursive: true);
      } catch (_) {}
    }
  }

  /// What the delete confirmation says when the place keeps deleted items
  /// (a cloud service's trash); null when they're gone for good.
  static String? deleteNote(Iterable<FileSystemEntity> entities) {
    for (final entity in entities) {
      if (entity is! RemoteEntity) continue;
      final place = RemotePlaces.instance.byId(entity.connectionId);
      final note = place == null ? null : RemoteProtocols.of(place.protocol)?.deleteNote;
      if (note != null) return note;
    }
    return null;
  }

  /// [entities] as copies on this device, for what needs real files
  /// (sharing with other apps, Nearby share); null if cancelled.
  static Future<List<FileSystemEntity>?> local(BuildContext context, List<FileSystemEntity> entities) =>
      RemoteEntity.anyIn(entities) ? RemoteOpener.fetch(context, entities) : Future.value(entities);
}

/// Buttons for the error page of a folder on a network place: trust a
/// changed server identity, or fix the place's sign-in.
List<Widget> remoteErrorActions(BuildContext context, FileExplorerError state) {
  final path = state.path;
  final error = state.error;
  final parsed = path == null ? null : RemotePaths.parse(path);
  if (parsed == null) return const [];
  final id = parsed.$1;
  final bloc = context.read<FileExplorerBloc>();
  if (error is RemoteTrustException) {
    return [
      OutlinedButton.icon(
        onPressed: () async {
          await error.trust();
          await RemotePool.instance.close(id);
          bloc.add(LoadDirectory(path!));
        },
        icon: const Icon(LucideIcons.shieldCheck, size: 16),
        label: const Text('Trust it and connect'),
      ),
    ];
  }
  final place = RemotePlaces.instance.byId(id);
  final fixAccess = place == null ? null : RemoteProtocols.of(place.protocol)?.fixAccess;
  if (error is RemoteException && fixAccess != null && (error.kind == RemoteErrorKind.auth || error.kind == RemoteErrorKind.permission)) {
    return [
      OutlinedButton.icon(
        onPressed: () async {
          if (await fixAccess(context) && !bloc.isClosed) {
            await RemotePool.instance.close(id);
            bloc.add(LoadDirectory(path!));
          }
        },
        icon: const Icon(LucideIcons.keyRound, size: 16),
        label: const Text('Set up access'),
      ),
    ];
  }
  if (error is RemoteException &&
      place != null &&
      !RemotePlaces.instance.isBuiltIn(id) &&
      (error.kind == RemoteErrorKind.auth || error.kind == RemoteErrorKind.network)) {
    return [
      OutlinedButton.icon(
        onPressed: () async {
          final saved = await showPlaceEditor(context, place: place);
          if (saved != null && !bloc.isClosed) bloc.add(LoadDirectory(path!));
        },
        icon: const Icon(LucideIcons.pencil, size: 16),
        label: const Text('Edit place'),
      ),
    ];
  }
  return const [];
}
