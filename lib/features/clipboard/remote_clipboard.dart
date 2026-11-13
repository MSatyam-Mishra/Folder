import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:folders/core/services/remote/remote_entities.dart';

/// Items of network places that were copied or cut. They stay in this app
/// (its tabs share them): other apps and windows couldn't read their
/// `explorer://remote` paths, so the system clipboard is cleared instead of
/// holding them. Anything copied afterwards, here or in another app, takes
/// their place.
abstract final class RemoteClipboard {
  static RemoteClipboardItems? held;

  /// Whether [entities] are to be held here rather than on the system
  /// clipboard.
  static bool holds(List<FileSystemEntity> entities) => RemoteEntity.anyIn(entities);

  @visibleForTesting
  static void reset() => held = null;
}

/// What [RemoteClipboard] holds.
@immutable
class RemoteClipboardItems {
  const RemoteClipboardItems(this.entities, {required this.cut});

  final List<FileSystemEntity> entities;
  final bool cut;

  List<String> get paths => [for (final e in entities) e.path];
}
