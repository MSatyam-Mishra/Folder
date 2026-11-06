import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Something another app sent to Folders.
sealed class IncomingItem {
  const IncomingItem();

  static IncomingItem _fromMap(Map<Object?, Object?> map) {
    final route = map['route'];
    if (route is String) return IncomingRoute(route);
    final text = map['text'];
    if (text is String) return IncomingLink(text);
    return IncomingFile._fromMap(map);
  }
}

/// A screen to show, e.g. from a tap on a download notification or a shortcut.
class IncomingRoute extends IncomingItem {
  const IncomingRoute(this.route);

  static const videoDownloader = 'video_downloader';
  static const fileServer = 'file_server';

  final String route;
}

/// Text shared to Folders ("Share → Folders"), e.g. a video page link.
class IncomingLink extends IncomingItem {
  const IncomingLink(this.text);

  final String text;

  /// The first web link in [text], if any.
  String? get url =>
      RegExp(r'https?://[^\s<>"]+', caseSensitive: false).firstMatch(text)?.group(0);
}

/// A file another app asked Folders to open ("Open with").
class IncomingFile extends IncomingItem {
  const IncomingFile({required this.uri, this.mime, this.writable = false});

  final String uri;
  final String? mime;

  /// Whether the sending app allows writing back to [uri].
  final bool writable;

  factory IncomingFile._fromMap(Map<Object?, Object?> map) => IncomingFile(
        uri: map['uri']! as String,
        mime: map['mime'] as String?,
        writable: map['writable'] == true,
      );
}

/// [IncomingFile] resolved to a local file a viewer can open.
class ResolvedIncomingFile {
  const ResolvedIncomingFile(this.file, {required this.isCopy});

  final File file;

  /// True when [file] is a cache copy whose edits must be written back.
  final bool isCopy;
}

class IncomingFileException implements Exception {
  const IncomingFileException(this.message, {this.cancelled = false});

  final String message;
  final bool cancelled;

  @override
  String toString() => message;
}

/// Android "Open with" support; see android/.../IncomingFiles.kt.
abstract final class IncomingFiles {
  static const _channel = MethodChannel('explorer/incoming');
  static final _incoming = StreamController<IncomingItem>.broadcast();
  static final _progress =
      StreamController<({String uri, int copied, int total})>.broadcast();
  static bool _listening = false;

  static bool get supported => !kIsWeb && Platform.isAndroid;

  /// Files and links received while the app is already running.
  static Stream<IncomingItem> get onIncoming {
    _listen();
    return _incoming.stream;
  }

  /// Copy progress for files that can't be read in place.
  static Stream<({String uri, int copied, int total})> get copyProgress {
    _listen();
    return _progress.stream;
  }

  static void _listen() {
    if (_listening || !supported) return;
    _listening = true;
    _channel.setMethodCallHandler((call) async {
      final args = call.arguments;
      if (args is! Map) return;
      switch (call.method) {
        case 'onIncoming':
          _incoming.add(IncomingItem._fromMap(args));
        case 'copyProgress':
          _progress.add((
            uri: args['uri'] as String,
            copied: (args['copied'] as num).toInt(),
            total: (args['total'] as num).toInt(),
          ));
      }
    });
  }

  /// The file or link the app was launched with, if any. Returns it once.
  static Future<IncomingItem?> takeInitial() async {
    if (!supported) return null;
    _listen();
    try {
      final map = await _channel.invokeMapMethod<Object?, Object?>('takeInitial');
      return map == null ? null : IncomingItem._fromMap(map);
    } on PlatformException catch (e) {
      debugPrint('Incoming file: $e');
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  static Future<ResolvedIncomingFile> resolve(IncomingFile incoming) async {
    try {
      final map = await _channel.invokeMapMethod<String, Object?>('resolve', {
        'uri': incoming.uri,
        'mime': incoming.mime,
      });
      return ResolvedIncomingFile(
        File(map!['path']! as String),
        isCopy: map['isCopy'] == true,
      );
    } on PlatformException catch (e) {
      throw IncomingFileException(
        e.message ?? "This file couldn't be opened.",
        cancelled: e.code == 'cancelled',
      );
    }
  }

  static Future<void> cancel(IncomingFile incoming) =>
      _channel.invokeMethod('cancel', {'uri': incoming.uri});

  /// Writes [file] back over the original content of [incoming].
  static Future<void> writeBack(IncomingFile incoming, File file) async {
    try {
      await _channel.invokeMethod('writeBack', {
        'uri': incoming.uri,
        'path': file.path,
      });
    } on PlatformException catch (e) {
      throw IncomingFileException(e.message ?? "Couldn't save the file.");
    }
  }
}
