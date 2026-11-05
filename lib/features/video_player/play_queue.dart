import 'dart:io';
import 'dart:math';
import 'dart:ui' show Offset, Size;

import 'package:path/path.dart' as p;

enum VideoRepeat {
  off('No repeat'),
  one('Repeat this video'),
  all('Repeat all');

  const VideoRepeat(this.label);

  final String label;
}

/// What's played, in what order.
class PlayQueue {
  PlayQueue(List<String> items, {int index = 0, Random? random})
      : _items = List.of(items),
        _random = random ?? Random(),
        _index = index.clamp(0, items.isEmpty ? 0 : items.length - 1);

  final List<String> _items;
  final Random _random;
  int _index;
  final _played = <int>[];

  VideoRepeat repeat = VideoRepeat.off;
  bool shuffle = false;

  List<String> get items => List.unmodifiable(_items);
  int get index => _index;
  String get current => _items[_index];

  /// The folder's other videos joined in: [items] in their order, staying on
  /// the one playing.
  void replaceAll(List<String> items) {
    final current = this.current;
    final at = items.indexOf(current);
    if (at < 0) return;
    _items
      ..clear()
      ..addAll(items);
    _index = at;
    _played.clear();
  }

  bool get hasNext => _items.length > 1 && (shuffle || repeat == VideoRepeat.all || _index + 1 < _items.length);
  bool get hasPrevious => _played.isNotEmpty || (_items.length > 1 && (repeat == VideoRepeat.all || _index > 0));

  /// Moves on, by the user's asking; false if there's nothing to move to.
  bool moveNext() {
    if (!hasNext) return false;
    _played.add(_index);
    if (shuffle) {
      var next = _random.nextInt(_items.length - 1);
      if (next >= _index) next++;
      _index = next;
    } else {
      _index = (_index + 1) % _items.length;
    }
    return true;
  }

  bool movePrevious() {
    if (_played.isNotEmpty) {
      _index = _played.removeLast();
      return true;
    }
    if (!hasPrevious) return false;
    _index = (_index - 1 + _items.length) % _items.length;
    return true;
  }

  /// A video ended by itself: what plays now? Null when it's all over.
  String? afterFinished() {
    if (repeat == VideoRepeat.one) return current;
    return moveNext() ? current : null;
  }
}

const subtitleExtensions = {'.srt', '.ass', '.ssa', '.vtt', '.sub', '.smi'};

/// Subtitle files beside [video] that belong to it: "movie.srt", "movie.en.srt".
/// The plain name first.
List<String> subtitlesBeside(String video, Iterable<String> filesInFolder) {
  final stem = p.basenameWithoutExtension(video).toLowerCase();
  final found = [
    for (final file in filesInFolder)
      if (subtitleExtensions.contains(p.extension(file).toLowerCase()) &&
          (p.basenameWithoutExtension(file).toLowerCase() == stem ||
              p.basename(file).toLowerCase().startsWith('$stem.')))
        file,
  ];
  found.sort((a, b) => p.basename(a).length.compareTo(p.basename(b).length));
  return found;
}

/// Whether one of mpv's errors is about a subtitle file rather than [video].
/// mpv reports them all alike, and a subtitle that won't open stops nothing.
bool isSubtitleError(String message, String video) {
  if (message.contains(p.basename(video))) return false;
  return RegExp(r'\.(srt|ass|ssa|vtt|sub|smi)\b', caseSensitive: false).hasMatch(message);
}

/// How far the picture is zoomed and moved, by a pinch.
class VideoView {
  const VideoView({this.zoom = 1, this.pan = Offset.zero});

  static const minZoom = 0.5;
  static const maxZoom = 5.0;

  /// Close to the picture's own size, it settles there.
  static const _snap = 0.04;

  final double zoom;
  final Offset pan;

  bool get isPlain => zoom == 1 && pan == Offset.zero;

  /// At [zoom] and [pan], moved no further than keeps the picture on a screen
  /// of [screen]; smaller than the screen, it stays in the middle.
  VideoView adjusted({double? zoom, Offset? pan, required Size screen}) {
    final next = (zoom ?? this.zoom).clamp(minZoom, maxZoom);
    final maxX = max(0.0, screen.width * (next - 1) / 2);
    final maxY = max(0.0, screen.height * (next - 1) / 2);
    final moved = pan ?? this.pan;
    return VideoView(
      zoom: next,
      pan: Offset(moved.dx.clamp(-maxX, maxX), moved.dy.clamp(-maxY, maxY)),
    );
  }

  /// At the end of a pinch.
  VideoView settled() => (zoom - 1).abs() < _snap ? const VideoView() : this;
}

/// What's in [folder], or nothing if it can't be read.
Future<List<String>> filesIn(String folder) async {
  try {
    return [
      await for (final entity in Directory(folder).list())
        if (entity is File) entity.path,
    ];
  } on FileSystemException {
    return const [];
  }
}

/// "02:03", or "1:02:03" for what lasts over an hour.
String formatVideoTime(Duration time) {
  final seconds = time.inSeconds.abs();
  String two(int value) => value.toString().padLeft(2, '0');
  final clock = seconds >= 3600
      ? '${seconds ~/ 3600}:${two(seconds ~/ 60 % 60)}:${two(seconds % 60)}'
      : '${two(seconds ~/ 60)}:${two(seconds % 60)}';
  return time.isNegative ? '-$clock' : clock;
}

/// A short name for what's played: a file's name, or a stream's last part or host.
String videoTitle(String path) {
  final uri = RegExp(r'^[a-zA-Z][a-zA-Z0-9+.-]+://').hasMatch(path) ? Uri.tryParse(path) : null;
  if (uri == null) return p.basename(path);
  final last = uri.pathSegments.isEmpty ? '' : uri.pathSegments.last;
  return last.isNotEmpty ? Uri.decodeComponent(last) : uri.host;
}

/// A stream address someone typed: what can be played of it, or null. A bare
/// "example.com/live" is taken as https.
String? cleanStreamAddress(String typed) {
  final text = typed.trim();
  if (text.isEmpty || text.contains(RegExp(r'\s'))) return null;
  final withScheme = RegExp(r'^[a-zA-Z][a-zA-Z0-9+.-]+://').hasMatch(text) ? text : 'https://$text';
  final uri = Uri.tryParse(withScheme);
  if (uri == null || uri.host.isEmpty) return null;
  return withScheme;
}
