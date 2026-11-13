import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:folders/core/files/file_types.dart';
import 'package:folders/core/services/remote/remote_entities.dart';
import 'package:folders/core/services/remote/remote_fs.dart';
import 'package:folders/core/services/remote/remote_pool.dart';

/// Pictures of small images on network places, fetched whole and kept in
/// memory; anything else shows its icon. The cost is capped: only common
/// image types up to [maxBytes], two at a time, [cacheBytes] kept.
abstract final class RemoteThumbnails {
  static const maxBytes = 3 * 1024 * 1024;
  static const cacheBytes = 48 * 1024 * 1024;
  static const _types = {'jpg', 'jpeg', 'png', 'gif', 'webp', 'bmp'};

  static final _cache = <String, Uint8List>{};
  static final _pending = <String, Future<Uint8List?>>{};
  static int _cached = 0;
  static int _running = 0;
  static final _waiting = Queue<Completer<void>>();

  /// Whether a picture of [path] may be fetched.
  static bool mayHave(String path) {
    final size = RemoteEntity.knownSize(path);
    return size != null && size > 0 && size <= maxBytes && _types.contains(FileTypes.extensionOf(path));
  }

  /// [path]'s bytes, or null; [wanted] says whether it's still on screen.
  static Future<Uint8List?> load(String path, {bool Function()? wanted}) {
    final key = '$path|${RemoteEntity.knownSize(path)}';
    final hit = _cache.remove(key);
    if (hit != null) {
      _cache[key] = hit;
      return Future.value(hit);
    }
    return _pending[key] ??= _fetch(path, key, wanted).whenComplete(() => _pending.remove(key));
  }

  static Future<Uint8List?> _fetch(String path, String key, bool Function()? wanted) async {
    final parsed = RemotePaths.parse(path);
    if (parsed == null) return null;
    if (_running >= 2) {
      final turn = Completer<void>();
      _waiting.add(turn);
      await turn.future;
    }
    _running++;
    try {
      if (wanted != null && !wanted()) return null;
      final builder = BytesBuilder(copy: false);
      await for (final chunk in RemotePool.instance.openRead(parsed.$1, parsed.$2, end: maxBytes)) {
        builder.add(chunk);
      }
      final bytes = builder.takeBytes();
      _cache[key] = bytes;
      _cached += bytes.length;
      while (_cached > cacheBytes && _cache.isNotEmpty) {
        final first = _cache.keys.first;
        _cached -= _cache.remove(first)!.length;
      }
      return bytes;
    } catch (_) {
      return null;
    } finally {
      _running--;
      if (_waiting.isNotEmpty) _waiting.removeFirst().complete();
    }
  }
}

/// [RemoteThumbnails]' picture of [path], [pixels] wide, or [fallback].
class RemoteThumbnail extends StatefulWidget {
  const RemoteThumbnail({
    super.key,
    required this.path,
    required this.pixels,
    required this.fit,
    required this.fallback,
    required this.frame,
  });

  final String path;
  final int pixels;
  final BoxFit fit;
  final Widget fallback;
  final Widget Function(Widget picture) frame;

  @override
  State<RemoteThumbnail> createState() => _RemoteThumbnailState();
}

class _RemoteThumbnailState extends State<RemoteThumbnail> {
  Future<Uint8List?>? _bytes;

  @override
  void initState() {
    super.initState();
    _request();
  }

  @override
  void didUpdateWidget(RemoteThumbnail oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.path != widget.path) _request();
  }

  void _request() {
    _bytes = RemoteThumbnails.mayHave(widget.path) ? RemoteThumbnails.load(widget.path, wanted: () => mounted) : null;
  }

  @override
  Widget build(BuildContext context) {
    final bytes = _bytes;
    if (bytes == null) return widget.fallback;
    return FutureBuilder<Uint8List?>(
      future: bytes,
      builder: (context, snapshot) {
        final data = snapshot.data;
        if (data == null) return widget.fallback;
        return widget.frame(Image.memory(
          data,
          fit: widget.fit,
          cacheWidth: widget.pixels,
          filterQuality: FilterQuality.medium,
          gaplessPlayback: true,
          errorBuilder: (_, _, _) => widget.fallback,
        ));
      },
    );
  }
}
