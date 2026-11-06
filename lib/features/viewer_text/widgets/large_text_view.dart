import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:folders/features/viewer_kit/viewer_kit.dart';
import 'package:folders/features/viewer_text/code_editor_controller.dart';
import 'package:folders/features/viewer_text/large_text_index.dart';
import 'package:folders/features/viewer_text/text_document.dart';
import 'package:flutter/material.dart';

/// What [LargeTextView] knows about the file so far.
class LargeTextStatus {
  const LargeTextStatus({
    required this.encoding,
    required this.lineCount,
    required this.complete,
  });

  final TextEncoding encoding;

  /// Lines indexed so far (all lines once [complete]).
  final int lineCount;
  final bool complete;
}

/// Progress of [LargeTextViewState.search].
class LargeTextSearch {
  const LargeTextSearch({
    required this.count,
    required this.current,
    required this.truncated,
    required this.busy,
  });

  static const idle = LargeTextSearch(count: 0, current: -1, truncated: false, busy: false);

  final int count;
  final int current;
  final bool truncated;
  final bool busy;
}

/// Read-only, virtualised view of a text file of any size.
///
/// Nothing proportional to the file size happens on the UI isolate: the
/// first screen comes from a small head read, a background isolate builds a
/// sparse line index (one checkpoint every [rowsPerBlock] rows), and only
/// the rows on screen are read from disk and decoded. Rows have a fixed
/// height, so scrolling, the scrollbar and "go to line" are exact.
class LargeTextView extends StatefulWidget {
  const LargeTextView({
    super.key,
    required this.file,
    required this.style,
    required this.strut,
    required this.lineHeight,
    this.onStatus,
    this.onSearch,
  });

  final File file;
  final TextStyle style;
  final StrutStyle strut;
  final double lineHeight;
  final ValueChanged<LargeTextStatus>? onStatus;
  final ValueChanged<LargeTextSearch>? onSearch;

  @override
  State<LargeTextView> createState() => LargeTextViewState();
}

class LargeTextViewState extends State<LargeTextView> {
  static const _headBytes = 128 * 1024;
  static const _maxSearchHits = 100000;

  final ScrollController _v = ScrollController();
  final ScrollController _h = ScrollController();
  final ScrollController _gutter = ScrollController();

  TextIndex? _index;
  int _fileLength = 0;
  String? _error;
  Isolate? _indexIsolate;
  ReceivePort? _indexPort;

  final LinkedHashMap<int, List<TextRow>> _blocks = LinkedHashMap();
  final Map<int, Future<List<TextRow>?>> _pendingBlocks = {};

  // Search state.
  Isolate? _searchIsolate;
  ReceivePort? _searchPort;
  Int64List _hits = Int64List(0);
  int _hitIndex = -1;
  int _hitLength = 0;
  bool _hitsTruncated = false;
  int _searchGeneration = 0;
  ({int row, int start, int end})? _highlight;

  double? _charWidthCache;
  TextStyle? _charWidthStyle;

  @override
  void initState() {
    super.initState();
    _v.addListener(_syncGutter);
    _open();
  }

  @override
  void didUpdateWidget(LargeTextView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.lineHeight != widget.lineHeight && _v.hasClients) {
      // Keep the same top row when the font size changes.
      final topRow = _v.offset / oldWidget.lineHeight;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_v.hasClients) {
          _v.jumpTo((topRow * widget.lineHeight)
              .clamp(0.0, _v.position.maxScrollExtent));
        }
      });
    }
  }

  @override
  void dispose() {
    _indexIsolate?.kill(priority: Isolate.immediate);
    _indexPort?.close();
    _searchIsolate?.kill(priority: Isolate.immediate);
    _searchPort?.close();
    _v.dispose();
    _h.dispose();
    _gutter.dispose();
    super.dispose();
  }

  void _syncGutter() {
    if (_gutter.hasClients && _gutter.offset != _v.offset) {
      _gutter.jumpTo(_v.offset.clamp(0.0, _gutter.position.maxScrollExtent));
    }
  }

  // ---- Indexing ------------------------------------------------------------

  Future<void> _open() async {
    try {
      final raf = await widget.file.open();
      final Uint8List head;
      try {
        _fileLength = await raf.length();
        head = await raf.read(_headBytes);
      } finally {
        await raf.close();
      }
      final complete = head.length >= _fileLength;
      final encoding = TextDocument.sniffEncoding(head, complete: complete);
      final bom = TextDocument.bomLength(encoding);
      // The first screen comes from the head alone (a few ms of work).
      final builder = TextIndexBuilder(encoding, bom)
        ..feed(head, 0, math.min(bom, head.length), head.length);
      if (!mounted) return;
      _setIndex(builder.build(complete: complete, length: head.length));
      if (!complete) _indexInBackground(encoding);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  Future<void> _indexInBackground(TextEncoding encoding) async {
    final port = ReceivePort();
    _indexPort = port;
    try {
      _indexIsolate = await Isolate.spawn(
        _indexEntry,
        (port.sendPort, widget.file.path, encoding),
      );
      final result = await port.first;
      if (!mounted) return;
      if (result is TextIndex) {
        _setIndex(result);
      } else {
        setState(() => _error = '$result');
      }
    } catch (_) {
      // Port closed by dispose.
    } finally {
      port.close();
      _indexIsolate = null;
    }
  }

  void _setIndex(TextIndex index) {
    // Blocks read with the head index stay valid unless they were cut short.
    _blocks.removeWhere((_, rows) => rows.length < rowsPerBlock);
    setState(() => _index = index);
    widget.onStatus?.call(LargeTextStatus(
      encoding: index.encoding,
      lineCount: index.lineCount,
      complete: index.complete,
    ));
  }

  // ---- Rows ------------------------------------------------------------------

  TextRow? _rowAt(int row) {
    final block = row ~/ rowsPerBlock;
    final rows = _blocks[block];
    if (rows == null) {
      _requestBlock(block);
      return null;
    }
    final i = row - block * rowsPerBlock;
    return i < rows.length ? rows[i] : null;
  }

  Future<List<TextRow>?> _requestBlock(int block) {
    final cached = _blocks[block];
    if (cached != null) return Future.value(cached);
    return _pendingBlocks[block] ??= _loadBlock(block).then((rows) {
      _pendingBlocks.remove(block);
      // null = the index was replaced mid-read; rebuilding asks again.
      if (rows == null && mounted) setState(() {});
      return rows;
    });
  }

  /// Reads and decodes one block. Returns null only when the index changed
  /// while reading; I/O errors give an empty block so they aren't retried in
  /// a loop.
  Future<List<TextRow>?> _loadBlock(int block) async {
    final index = _index;
    if (index == null || block >= index.blockCount) return const [];
    final (start, end, _) = index.blockRange(block);
    List<TextRow> rows;
    try {
      rows = index.splitBlock(block, await _readRange(start, end));
    } catch (_) {
      rows = const [];
    }
    if (!mounted) return rows;
    if (!identical(index, _index)) return null;
    while (_blocks.length >= 256) {
      _blocks.remove(_blocks.keys.first);
    }
    setState(() => _blocks[block] = rows);
    return rows;
  }

  Future<Uint8List> _readRange(int start, int end) async {
    final out = BytesBuilder(copy: false);
    await for (final chunk in widget.file.openRead(start, end)) {
      out.add(chunk);
    }
    return out.takeBytes();
  }

  // ---- Navigation ------------------------------------------------------------

  /// Scrolls so [line] (1-based) is near the top.
  Future<void> goToLine(int line) async {
    final index = _index;
    if (index == null || index.blockCount == 0) return;
    final block = index.blockForLine(line);
    final rows = await _requestBlock(block);
    if (!mounted) return;
    var row = block * rowsPerBlock;
    if (rows != null) {
      for (var i = 0; i < rows.length; i++) {
        row = block * rowsPerBlock + i;
        if (rows[i].line >= line) break;
      }
    }
    _revealRow(row);
  }

  void _revealRow(int row, {int? column}) {
    if (!_v.hasClients) return;
    final viewport = _v.position.viewportDimension;
    final target = (row * widget.lineHeight - viewport / 3)
        .clamp(0.0, _v.position.maxScrollExtent);
    _v.jumpTo(target);
    if (!_h.hasClients) return;
    if (column != null) {
      final x = column * _charWidth();
      final width = _h.position.viewportDimension;
      if (x < _h.offset || x > _h.offset + width - 48) {
        _h.jumpTo((x - width / 3).clamp(0.0, _h.position.maxScrollExtent));
      }
    } else if (_h.offset != 0) {
      _h.jumpTo(0);
    }
  }

  // ---- Search ----------------------------------------------------------------

  /// Finds [query] in the whole file (in a background isolate). Case folding
  /// applies to ASCII letters only.
  Future<void> search(String query, {required bool caseSensitive}) async {
    final generation = ++_searchGeneration;
    _searchIsolate?.kill(priority: Isolate.immediate);
    _searchPort?.close();
    _searchIsolate = null;
    final index = _index;
    setState(() {
      _hits = Int64List(0);
      _hitIndex = -1;
      _highlight = null;
      _hitsTruncated = false;
    });
    final needle = index == null || query.isEmpty
        ? null
        : encodeSearchNeedle(query, index.encoding);
    if (index == null || needle == null || needle.isEmpty) {
      widget.onSearch?.call(LargeTextSearch.idle);
      return;
    }
    widget.onSearch?.call(
      const LargeTextSearch(count: 0, current: -1, truncated: false, busy: true),
    );
    final port = ReceivePort();
    _searchPort = port;
    try {
      _searchIsolate = await Isolate.spawn(_searchEntry, (
        port.sendPort,
        widget.file.path,
        needle,
        index.encoding,
        caseSensitive,
        _maxSearchHits,
      ));
      final result = await port.first;
      if (!mounted || generation != _searchGeneration) return;
      if (result is! Int64List) {
        widget.onSearch?.call(LargeTextSearch.idle);
        return;
      }
      _hits = result;
      _hitLength = query.length;
      _hitsTruncated = result.length >= _maxSearchHits;
      if (result.isNotEmpty) {
        // Start at the first hit at or below the current scroll position.
        await _gotoHit(_firstHitBelowTop());
      } else {
        _report();
      }
    } catch (_) {
      // Cancelled.
    } finally {
      port.close();
      if (generation == _searchGeneration) _searchIsolate = null;
    }
  }

  void nextHit() {
    if (_hits.isNotEmpty) _gotoHit((_hitIndex + 1) % _hits.length);
  }

  void previousHit() {
    if (_hits.isNotEmpty) {
      _gotoHit((_hitIndex - 1 + _hits.length) % _hits.length);
    }
  }

  int _firstHitBelowTop() {
    final index = _index;
    if (index == null || !_v.hasClients) return 0;
    final topBlock = (_v.offset / widget.lineHeight).floor() ~/ rowsPerBlock;
    if (topBlock >= index.blockCount) return 0;
    final offset = index.blockStarts[topBlock];
    var lo = 0, hi = _hits.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (_hits[mid] < offset) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return lo >= _hits.length ? 0 : lo;
  }

  Future<void> _gotoHit(int i) async {
    final index = _index;
    if (index == null || i < 0 || i >= _hits.length) return;
    _hitIndex = i;
    _report();
    final offset = _hits[i];
    final block = index.blockForOffset(offset);
    final rows = await _requestBlock(block);
    if (!mounted || rows == null || i != _hitIndex) return;
    for (var r = 0; r < rows.length; r++) {
      final row = rows[r];
      if (offset >= row.start && (offset < row.end || r == rows.length - 1)) {
        final prefix = await _readRange(row.start, offset);
        if (!mounted || i != _hitIndex) return;
        final column = TextDocument.decodeSlice(prefix, index.encoding).length;
        final rowIndex = block * rowsPerBlock + r;
        setState(() => _highlight = (
              row: rowIndex,
              start: column,
              end: math.min(column + _hitLength, row.text.length),
            ));
        _revealRow(rowIndex, column: column);
        return;
      }
    }
  }

  void _report() {
    widget.onSearch?.call(LargeTextSearch(
      count: _hits.length,
      current: _hitIndex,
      truncated: _hitsTruncated,
      busy: false,
    ));
  }

  // ---- UI --------------------------------------------------------------------

  double _charWidth() {
    final cached = _charWidthCache;
    if (cached != null && _charWidthStyle == widget.style) return cached;
    final painter = TextPainter(
      text: TextSpan(text: 'M', style: widget.style),
      textDirection: TextDirection.ltr,
    )..layout();
    _charWidthStyle = widget.style;
    final width = painter.width;
    painter.dispose();
    return _charWidthCache = width;
  }

  @override
  Widget build(BuildContext context) {
    final error = _error;
    if (error != null) {
      return ViewerMessage(
        icon: LucideIcons.fileX2,
        title: "Couldn't read this file",
        details: error,
      );
    }
    final index = _index;
    if (index == null) return const ViewerLoading();

    final colors = context.colors;
    final charWidth = _charWidth();
    // Reserve gutter digits for the estimated final line count so the width
    // doesn't jump when indexing finishes.
    final estimatedLines = index.complete || index.endOffset <= 0
        ? index.lineCount
        : (index.lineCount * _fileLength / index.endOffset).ceil();
    final gutterWidth = 20 + '$estimatedLines'.length * charWidth;
    final maxRowChars = index.maxRowLength ~/ index.unit;
    final gutterStyle = widget.style.copyWith(
      color: colors.mutedForeground.withValues(alpha: 0.75),
    );
    final highlight = CodeTheme.of(context).currentMatch;

    return LayoutBuilder(
      builder: (context, constraints) {
        final contentWidth = math.max(
          constraints.maxWidth - gutterWidth,
          (maxRowChars + 4) * charWidth + 28,
        );
        final list = ListView.builder(
          controller: _v,
          padding: const EdgeInsets.fromLTRB(12, 12, 16, 48),
          itemExtent: widget.lineHeight,
          itemCount: index.rowCount,
          itemBuilder: (context, r) {
            final text = _rowAt(r)?.text ?? '';
            final hl = _highlight;
            final span = hl != null &&
                    hl.row == r &&
                    hl.end > hl.start &&
                    hl.end <= text.length
                ? TextSpan(children: [
                    TextSpan(text: text.substring(0, hl.start)),
                    TextSpan(
                      text: text.substring(hl.start, hl.end),
                      style: TextStyle(backgroundColor: highlight),
                    ),
                    TextSpan(text: text.substring(hl.end)),
                  ])
                : TextSpan(text: text);
            return Text.rich(
              span,
              maxLines: 1,
              softWrap: false,
              overflow: TextOverflow.clip,
              style: widget.style,
              strutStyle: widget.strut,
            );
          },
        );

        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              width: gutterWidth,
              decoration: BoxDecoration(
                color: colors.muted.withValues(alpha: 0.35),
                border: Border(right: BorderSide(color: colors.border)),
              ),
              child: ScrollConfiguration(
                behavior: const ScrollBehavior().copyWith(scrollbars: false),
                child: ListView.builder(
                  controller: _gutter,
                  physics: const NeverScrollableScrollPhysics(),
                  padding: const EdgeInsets.fromLTRB(4, 12, 10, 48),
                  itemExtent: widget.lineHeight,
                  itemCount: index.rowCount,
                  itemBuilder: (context, r) {
                    final row = _rowAt(r);
                    return Text(
                      row == null || row.continuation ? '' : '${row.line}',
                      textAlign: TextAlign.right,
                      maxLines: 1,
                      style: gutterStyle,
                      strutStyle: widget.strut,
                    );
                  },
                ),
              ),
            ),
            Expanded(
              child: Scrollbar(
                controller: _v,
                interactive: true,
                thumbVisibility: index.rowCount > 2000,
                notificationPredicate: (n) => n.metrics.axis == Axis.vertical,
                child: Scrollbar(
                  controller: _h,
                  notificationPredicate: (n) =>
                      n.depth == 0 && n.metrics.axis == Axis.horizontal,
                  child: SingleChildScrollView(
                    controller: _h,
                    scrollDirection: Axis.horizontal,
                    child: SizedBox(
                      width: contentWidth,
                      height: constraints.maxHeight,
                      child: SelectionArea(child: list),
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// Background isolate: indexes the whole file.
void _indexEntry((SendPort, String, TextEncoding) args) {
  final (port, path, encoding) = args;
  Object result;
  try {
    result = indexTextFile(path, encoding);
  } catch (e) {
    result = '$e';
  }
  Isolate.exit(port, result);
}

/// Background isolate: offsets of every match.
void _searchEntry((SendPort, String, Uint8List, TextEncoding, bool, int) args) {
  final (port, path, needle, encoding, caseSensitive, maxHits) = args;
  Object result;
  try {
    result = searchTextFile(
      path,
      needle,
      encoding,
      caseSensitive: caseSensitive,
      maxHits: maxHits,
    );
  } catch (e) {
    result = '$e';
  }
  Isolate.exit(port, result);
}
